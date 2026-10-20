import SwiftUI
import UniformTypeIdentifiers

/// Source management: enable/disable, install, configure and remove providers.
struct SourcesSettingsView: View {
    @Environment(SourcesModel.self) private var model
    @Environment(SourceHealthChecker.self) private var checker
    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var app

    @State private var showingFileImporter = false
    @State private var showingURLSheet = false
    @State private var showingSourceBrowser = false
    @State private var manifestURLText = ""

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Text("Providers are scripts that run in a restricted JavaScript sandbox. They can only reach the hosts their manifest declares.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sources") {
                LabeledContent("Available", value: "\(model.sources.count)")
                LabeledContent("Enabled", value: "\(model.sources.filter(\.isEnabled).count)")
                LabeledContent("Pinned", value: "\(model.pinnedCount)")

                Button {
                    showingSourceBrowser = true
                } label: {
                    Label("See Sources…", systemImage: "list.bullet.rectangle")
                }
            }

            Section("Content") {
                Toggle("Hide NSFW results", isOn: $settings.hideNSFWResults)
                Text("Erotica and pornographic titles are hidden from Browse and Global Search. This also limits MangaDex to safe and suggestive titles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            parserSection

            Section("Install") {
                HStack(spacing: 10) {
                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("Install from File…", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        manifestURLText = ""
                        showingURLSheet = true
                    } label: {
                        Label("Install from URL…", systemImage: "link")
                    }

                    Button {
                        Task { await model.installBundledSample() }
                    } label: {
                        Label("Install Example Provider", systemImage: "sparkles")
                    }
                    .disabled(model.isInstalling)
                }
                .buttonStyle(.bordered)

                if model.isInstalling {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Working…").foregroundStyle(.secondary)
                    }
                }
            }

            if let message = model.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            if let message = model.infoMessage {
                Section {
                    Label(message, systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await model.refresh()
        }
        .onChange(of: settings.hideNSFWResults) { _, _ in
            Task { await app.refreshProviders() }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await model.install(bundleAt: url) }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingURLSheet) {
            installFromURLSheet
        }
        .sheet(isPresented: $showingSourceBrowser) {
            SourceBrowserSheet()
        }
    }

    /// Everything the parser library ships, switchable, with a check that finds the
    /// ones that actually work. Individual rows live under See Sources.
    @ViewBuilder
    private var parserSection: some View {
        Section("Kotatsu (parser host)") {
            if let reason = model.kotatsuUnavailableReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.kotatsuSources.isEmpty {
                Text("No Kotatsu sources are registered.")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Button {
                        checker.start(sources: model.kotatsuSources.filter(\.isEnabled))
                    } label: {
                        Label("Check Selected Sources", systemImage: "stethoscope")
                    }
                    .disabled(
                        checker.isRunning
                            || !model.kotatsuSources.contains(where: \.isEnabled)
                    )
                    .help("Check the Kotatsu sources currently enabled in See Sources.")

                    Button {
                        // Kept visible but disabled: checking only untested sources
                        // is no longer offered.
                    } label: {
                        Label("Check Unchecked", systemImage: "arrow.clockwise")
                    }
                    .disabled(true)

                    if checker.isRunning {
                        Button("Stop") { checker.cancel() }
                    }
                }

                if checker.isRunning {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: checker.progress) {
                            Text("\(checker.completed) of \(checker.total)")
                                .font(.caption)
                        }
                        if let name = checker.currentSourceName {
                            Text("Checking \(name)…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let summary = checker.lastRunSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(summary.contains("0 working") ? .orange : .secondary)
                }

                Text("\(model.kotatsuSources.count) sources available · \(model.kotatsuWorkingCount) known working · \(model.kotatsuEnabledCount) enabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Open See Sources to search, pin, enable or configure individual providers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var installFromURLSheet: some View {
        VStack(spacing: 16) {
            Text("Install from URL")
                .font(.headline)
            Text("Enter the HTTPS address of a provider's manifest.json.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("https://example.com/provider/manifest.json", text: $manifestURLText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
            HStack {
                Button("Cancel") { showingURLSheet = false }
                Button("Install") {
                    let text = manifestURLText
                    showingURLSheet = false
                    guard let url = URL(string: text) else {
                        model.errorMessage = "That is not a valid URL."
                        return
                    }
                    Task { await model.install(manifestURL: url) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(URL(string: manifestURLText) == nil)
            }
        }
        .padding(24)
    }
}

/// Searchable source browser. Disabled sources are hidden by default; the toggle
/// changes the range the search runs over. Pinned sources sort first.
private struct SourceBrowserSheet: View {
    @Environment(SourcesModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var showAllSources = false
    @State private var languageFilter = "all"
    @State private var categoryFilter = "all"
    @State private var isUpdatingSelection = false
    @State private var configurationTarget: SourceManifest?
    @State private var removalTarget: SourceInfo?

    private var filteredSources: [SourceInfo] {
        model.visibleSources(
            includeDisabled: showAllSources,
            query: searchText
        )
        .filter { source in
            languageFilter == "all"
                || source.language.caseInsensitiveCompare(languageFilter) == .orderedSame
        }
        .filter { source in
            categoryFilter == "all"
                || SourceContentType.category(for: source.contentType).rawValue == categoryFilter
        }
    }

    private var availableLanguages: [String] {
        Array(Set(model.sources.map(\.language)))
            .sorted {
                languageName($0).localizedStandardCompare(languageName($1))
                    == .orderedAscending
            }
    }

    private func languageName(_ code: String) -> String {
        if code.caseInsensitiveCompare("multi") == .orderedSame {
            return "Multilingual"
        }
        return Locale.current.localizedString(forIdentifier: code)
            ?? code.uppercased()
    }

    private func setEnabledForFiltered(_ enabled: Bool) {
        let ids = Set(filteredSources.map(\.id))
        guard !ids.isEmpty else { return }
        isUpdatingSelection = true
        Task {
            await model.setEnabled(enabled, sourceIds: ids)
            isUpdatingSelection = false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("See Sources")
                        .font(.title2.weight(.semibold))
                    Text("Search, enable, pin and configure providers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)

            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search sources", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

                Toggle("Show all sources", isOn: $showAllSources)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            .padding(.horizontal, 18)

            HStack(spacing: 10) {
                Picker("Language", selection: $languageFilter) {
                    Text("All languages").tag("all")
                    ForEach(availableLanguages, id: \.self) { language in
                        Text(languageName(language)).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 145, alignment: .leading)

                Picker("Category", selection: $categoryFilter) {
                    Text("All categories").tag("all")
                    ForEach(SourceContentType.allCases) { contentType in
                        Text(contentType.displayName).tag(contentType.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 145, alignment: .leading)

                Spacer()

                Button("Select All") {
                    setEnabledForFiltered(true)
                }
                .disabled(
                    isUpdatingSelection
                        || filteredSources.isEmpty
                        || filteredSources.allSatisfy(\.isEnabled)
                )

                Button("Deselect All") {
                    setEnabledForFiltered(false)
                }
                .disabled(
                    isUpdatingSelection
                        || filteredSources.isEmpty
                        || filteredSources.allSatisfy { !$0.isEnabled }
                )

                if isUpdatingSelection {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)

            HStack {
                Text("\(filteredSources.count) sources")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let error = model.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)

            Divider()

            if filteredSources.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No Sources" : "No Matching Sources",
                    systemImage: "magnifyingglass",
                    description: Text(
                        showAllSources
                            ? "No providers match these filters."
                            : "No enabled providers match these filters. Turn on “Show all sources” to search all providers."
                    )
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredSources) { source in
                        SourceRow(
                            source: source,
                            manifest: model.manifest(for: source),
                            health: source.provider == .kotatsuHost
                                ? model.health(of: source)
                                : nil,
                            healthDetail: source.provider == .kotatsuHost
                                ? model.healthDetail(of: source)
                                : nil,
                            onToggle: { enabled, id in
                                Task { await model.setEnabled(enabled, id: id) }
                            },
                            onPin: { pinned, id in
                                Task { await model.setPinned(pinned, id: id) }
                            },
                            onConfigure: { manifest in
                                configurationTarget = manifest
                            },
                            onRemove: source.provider == .scripted
                                ? { source in removalTarget = source }
                                : nil
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 700, height: 600)
        .task {
            await model.refresh()
        }
        .sheet(item: $configurationTarget) { manifest in
            ProviderConfigurationSheet(manifest: manifest, model: model)
        }
        .alert("Remove Provider?", isPresented: Binding(
            get: { removalTarget != nil },
            set: { if !$0 { removalTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) { removalTarget = nil }
            Button("Remove", role: .destructive) {
                if let target = removalTarget {
                    Task { await model.remove(id: target.id) }
                }
                removalTarget = nil
            }
        } message: {
            Text("“\(removalTarget?.name ?? "")” will be deleted. Manga already in your library stays, but reading it will fail until you reinstall the provider.")
        }
    }
}

private struct SourceRow: View {
    let source: SourceInfo
    let manifest: SourceManifest?
    var health: SourceHealth?
    var healthDetail: String?
    let onToggle: (Bool, String) -> Void
    var onPin: ((Bool, String) -> Void)?
    let onConfigure: ((SourceManifest) -> Void)?
    let onRemove: ((SourceInfo) -> Void)?

    var body: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { source.isEnabled },
                set: { onToggle($0, source.id) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(source.name)
                        if source.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                        }
                        if let health, let badge = health.badge {
                            Text(badge.text)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(badge.color.opacity(0.15), in: Capsule())
                                .foregroundStyle(badge.color)
                        }
                    }
                    HStack(spacing: 6) {
                        Text("v\(source.version)")
                        Text("·")
                        Text(source.language.uppercased())
                        Text("·")
                        Text(source.contentType.capitalized)
                        if source.isBuiltIn {
                            Text("· Built-in")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if let healthDetail, !healthDetail.isEmpty {
                        Text(healthDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .toggleStyle(.switch)

            Spacer()

            if let onPin {
                Button {
                    onPin(!source.isPinned, source.id)
                } label: {
                    Image(systemName: source.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(source.isPinned ? Color.accentColor : Color.secondary)
                .help(source.isPinned ? "Unpin source" : "Pin source")
            }

            if let manifest, !manifest.config.isEmpty, let onConfigure {
                Button {
                    onConfigure(manifest)
                } label: {
                    Label("Configure", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
            }

            if let onRemove, !source.isBuiltIn {
                Button(role: .destructive) {
                    onRemove(source)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

private extension SourceHealth {
    var badge: (text: String, color: Color)? {
        switch self {
        case .working: ("working", .green)
        case .failing: ("not working", .orange)
        case .untested: nil
        }
    }
}

/// Form generated from the manifest's declared configuration fields.
private struct ProviderConfigurationSheet: View {
    let manifest: SourceManifest
    let model: SourcesModel

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Configure \(manifest.name)")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            Form {
                ForEach(manifest.config) { field in
                    switch field.type {
                    case .text:
                        TextField(field.label, text: binding(for: field.key))
                    case .toggle:
                        Toggle(field.label, isOn: Binding(
                            get: { (values[field.key] ?? "false") == "true" },
                            set: { values[field.key] = $0 ? "true" : "false" }
                        ))
                    case .select:
                        Picker(field.label, selection: binding(for: field.key)) {
                            ForEach(field.options ?? [], id: \.self) { option in
                                Text(option).tag(option)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let snapshot = values
                    dismiss()
                    Task { await model.applyConfiguration(id: manifest.id, values: snapshot) }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 420, height: 320)
        .onAppear {
            values = model.configuration(for: manifest)
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { values[key] = $0 }
        )
    }
}
