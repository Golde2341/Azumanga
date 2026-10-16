import SwiftUI
import UniformTypeIdentifiers

/// Source management: enable/disable, install, configure and remove providers.
struct SourcesSettingsView: View {
    @Environment(SourcesModel.self) private var model

    @State private var showingFileImporter = false
    @State private var showingURLSheet = false
    @State private var manifestURLText = ""
    @State private var configurationTarget: SourceManifest?
    @State private var removalTarget: SourceInfo?

    var body: some View {
        Form {
            Section {
                Text("Providers are scripts that run in a restricted JavaScript sandbox. They can only reach the hosts their manifest declares.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Built-in") {
                if model.builtInSources.isEmpty {
                    Text("No built-in sources registered.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.builtInSources) { source in
                        SourceRow(source: source, manifest: nil, onToggle: setEnabled, onConfigure: nil, onRemove: nil)
                    }
                }
            }

            Section("Installed") {
                if model.installedSources.isEmpty {
                    Text("No third-party sources are installed.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.installedSources) { source in
                        SourceRow(
                            source: source,
                            manifest: model.manifest(for: source),
                            onToggle: setEnabled,
                            onConfigure: { manifest in configurationTarget = manifest },
                            onRemove: { _ in removalTarget = source }
                        )
                    }
                }

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

    private func setEnabled(_ enabled: Bool, _ id: String) {
        Task { await model.setEnabled(enabled, id: id) }
    }
}

private struct SourceRow: View {
    let source: SourceInfo
    let manifest: SourceManifest?
    let onToggle: (Bool, String) -> Void
    let onConfigure: ((SourceManifest) -> Void)?
    let onRemove: ((SourceInfo) -> Void)?

    var body: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { source.isEnabled },
                set: { onToggle($0, source.id) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                    HStack(spacing: 6) {
                        Text("v\(source.version)")
                        Text("·")
                        Text(source.language.uppercased())
                        if source.isBuiltIn {
                            Text("· Built-in")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Spacer()

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
