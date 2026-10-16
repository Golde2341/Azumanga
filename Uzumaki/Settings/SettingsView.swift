import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        TabView {
            ReadingSettingsView()
                .tabItem { Label("Reading", systemImage: "book") }

            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }

            SourcesSettingsView()
                .tabItem { Label("Sources", systemImage: "square.stack.3d.up") }

            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            StorageSettingsView()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

/// Reference for the keyboard and gesture shortcuts the app responds to.
private struct ShortcutsSettingsView: View {
    private struct Shortcut: Identifiable {
        let id = UUID()
        let action: String
        let keys: String
    }

    private let readerGroups: [(title: String, shortcuts: [Shortcut])] = [
        ("Pages", [
            Shortcut(action: "Next page", keys: "→  ↓  Space  Page Down"),
            Shortcut(action: "Previous page", keys: "←  ↑  Page Up"),
            Shortcut(action: "Next chapter", keys: "]"),
            Shortcut(action: "Previous chapter", keys: "["),
        ]),
        ("Zoom", [
            Shortcut(action: "Zoom in", keys: "+"),
            Shortcut(action: "Zoom out", keys: "−"),
            Shortcut(action: "Fit page", keys: "0"),
            Shortcut(action: "Toggle zoom", keys: "Double-click, or pinch"),
        ]),
        ("Reading", [
            Shortcut(action: "Bookmark this page", keys: "B"),
            Shortcut(action: "Mark chapter as read", keys: "M"),
            Shortcut(action: "Toggle full screen", keys: "F"),
            Shortcut(action: "Close the reader", keys: "Esc"),
        ]),
    ]

    private let appShortcuts: [Shortcut] = [
        Shortcut(action: "Search", keys: "⌘F"),
        Shortcut(action: "Reload the library", keys: "⌘⇧R"),
        Shortcut(action: "Reload the current screen", keys: "⌘R"),
    ]

    var body: some View {
        Form {
            ForEach(readerGroups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.shortcuts) { shortcut in
                        LabeledContent(shortcut.action) {
                            Text(shortcut.keys)
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("App") {
                ForEach(appShortcuts) { shortcut in
                    LabeledContent(shortcut.action) {
                        Text(shortcut.keys)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ReadingSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Layout") {
                Picker("Reading mode", selection: $settings.layout) {
                    ForEach(ReaderLayoutKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                Picker("Reading direction", selection: $settings.direction) {
                    ForEach(ReadingDirection.allCases) { direction in
                        Text(direction.displayName).tag(direction)
                    }
                }
                Picker("Pages", selection: $settings.pageMode) {
                    ForEach(PageMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker("Fit", selection: $settings.fitMode) {
                    ForEach(PageFitMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Toggle("Keep the first page alone in double-page mode", isOn: $settings.doublePageFirstPageAlone)
            }

            Section("Performance") {
                Stepper("Prefetch \(settings.prefetchDistance) page\(settings.prefetchDistance == 1 ? "" : "s") ahead", value: $settings.prefetchDistance, in: 0...10)
            }

            Section("Sources") {
                Toggle("Download smaller (data saver) images", isOn: $settings.prefersDataSaver)
                TextField("Translated language", text: $settings.language)
                    .onSubmit { Task { await app.refreshProviders() } }
                Picker("Content", selection: Binding(
                    get: { settings.contentRatings.contains(.pornographic) ? "all" : "safe" },
                    set: { newValue in
                        settings.contentRatings = newValue == "all"
                            ? Set(ContentRating.allCases)
                            : ContentRating.safeDefaults
                        Task { await app.refreshProviders() }
                    }
                )) {
                    Text("Safe and suggestive").tag("safe")
                    Text("Include adult content").tag("all")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.prefersDataSaver) { _, _ in
            Task { await app.refreshProviders() }
        }
    }
}

private struct AppearanceSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Reader background") {
                Picker("Background", selection: $settings.background) {
                    ForEach(PageBackground.allCases) { background in
                        Text(background.displayName).tag(background)
                    }
                }
                .pickerStyle(.inline)

                HStack(spacing: 10) {
                    ForEach(PageBackground.allCases) { background in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(background.color)
                            .frame(height: 36)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(settings.background == background ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: settings.background == background ? 2 : 1)
                            }
                            .onTapGesture { settings.background = background }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct StorageSettingsView: View {
    @Environment(Services.self) private var services
    @Environment(AppEnvironment.self) private var app

    @State private var imageCacheBytes: Int64 = 0
    @State private var downloadBytes: Int64 = 0

    var body: some View {
        Form {
            Section("Image Cache") {
                LabeledContent("Cached images", value: byteString(imageCacheBytes))
                Button("Clear Image Cache") {
                    Task {
                        await services.images.clearDisk()
                        await services.images.clearMemory()
                        await refresh()
                    }
                }
            }

            Section("Downloads") {
                LabeledContent("Offline chapters", value: byteString(downloadBytes))
                Text("Manage individual downloads in the Downloads section.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
    }

    private func refresh() async {
        imageCacheBytes = await services.images.diskUsage()
        downloadBytes = (try? services.downloadStore.totalByteCount()) ?? 0
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension PageBackground {
    var color: Color {
        switch self {
        case .black: .black
        case .darkGray: Color(white: 0.12)
        case .white: .white
        }
    }
}
