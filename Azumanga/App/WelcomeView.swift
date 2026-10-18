import SwiftUI

/// First-run welcome. The languages and content types picked here seed the native
/// MangaDex source and the locale-specific sources provided by the parser host.
struct WelcomeView: View {
    @Environment(AppEnvironment.self) private var app

    let onFinished: () -> Void

    @State private var selectedLanguages: Set<String>
    @State private var selectedContentTypes: Set<SourceContentType>
    @State private var isApplying = false

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        _selectedLanguages = State(initialValue: [WelcomeLanguage.systemDefault])
        _selectedContentTypes = State(initialValue: SourceContentType.safeDefaults)
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 42))
                .foregroundStyle(.tint)

            VStack(spacing: 7) {
                Text("Welcome to Azumanga")
                    .font(.largeTitle.weight(.semibold))

                Text("Read manga from the built-in MangaDex source and the bundled Kotatsu parser.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            languageSection
            contentTypeSection

            Text("Parser sources are enabled when they match a selected language and content type. You can fine-tune individual sources later in Settings → Sources.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await finish() }
            } label: {
                HStack(spacing: 8) {
                    if isApplying {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isApplying ? "Setting up sources…" : "Get Started")
                }
                .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(
                isApplying
                    || selectedLanguages.isEmpty
                    || selectedContentTypes.isEmpty
            )
        }
        .padding(28)
        .frame(width: 600)
        .interactiveDismissDisabled()
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Languages")
                        .font(.headline)
                    Text("Select every language you read in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear") {
                    selectedLanguages.removeAll()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(selectedLanguages.isEmpty)
            }

            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), alignment: .leading),
                        GridItem(.flexible(), alignment: .leading),
                    ],
                    alignment: .leading,
                    spacing: 7
                ) {
                    ForEach(WelcomeLanguage.all) { language in
                        Toggle(
                            language.name,
                            isOn: languageBinding(language.id)
                        )
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private var contentTypeSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Content")
                    .font(.headline)
                Text("Choose the kinds of parser sources to enable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading),
                ],
                alignment: .leading,
                spacing: 7
            ) {
                ForEach(SourceContentType.allCases) { contentType in
                    Toggle(
                        contentType.displayName,
                        isOn: contentTypeBinding(contentType)
                    )
                    .toggleStyle(.checkbox)
                }
            }

            Text("Hentai sources stay off unless you explicitly select Hentai.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private func languageBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selectedLanguages.contains(id) },
            set: { isSelected in
                if isSelected {
                    selectedLanguages.insert(id)
                } else {
                    selectedLanguages.remove(id)
                }
            }
        )
    }

    private func contentTypeBinding(_ contentType: SourceContentType) -> Binding<Bool> {
        Binding(
            get: { selectedContentTypes.contains(contentType) },
            set: { isSelected in
                if isSelected {
                    selectedContentTypes.insert(contentType)
                } else {
                    selectedContentTypes.remove(contentType)
                }
            }
        )
    }

    private func finish() async {
        guard !isApplying, !selectedLanguages.isEmpty, !selectedContentTypes.isEmpty else {
            return
        }
        isApplying = true

        let systemLanguage = WelcomeLanguage.systemDefault
        var orderedLanguages = selectedLanguages.contains(systemLanguage)
            ? [systemLanguage]
            : []
        orderedLanguages.append(contentsOf: WelcomeLanguage.all
            .map(\.id)
            .filter { selectedLanguages.contains($0) && !orderedLanguages.contains($0) })
        await app.applyWelcomeSelection(
            languages: orderedLanguages,
            contentTypes: selectedContentTypes
        )

        isApplying = false
        onFinished()
    }
}

private struct WelcomeLanguage: Identifiable, Hashable {
    let id: String

    var name: String {
        Locale.current.localizedString(forIdentifier: id)
            ?? Locale.current.localizedString(forLanguageCode: id)
            ?? id
    }

    static let all: [WelcomeLanguage] = [
        .init(id: "en"),
        .init(id: "es"),
        .init(id: "pt-BR"),
        .init(id: "fr"),
        .init(id: "de"),
        .init(id: "it"),
        .init(id: "ru"),
        .init(id: "uk"),
        .init(id: "pl"),
        .init(id: "tr"),
        .init(id: "ar"),
        .init(id: "id"),
        .init(id: "vi"),
        .init(id: "th"),
        .init(id: "ja"),
        .init(id: "ko"),
        .init(id: "zh"),
        .init(id: "hi"),
        .init(id: "nl"),
        .init(id: "cs"),
        .init(id: "ro"),
        .init(id: "hu"),
        .init(id: "el"),
    ]

    static var systemDefault: String {
        let code = Locale.current.language.languageCode?.identifier.lowercased() ?? "en"
        return all.first { language in
            let id = language.id.lowercased()
            return id == code
                || id.hasPrefix(code + "-")
                || code.hasPrefix(id + "-")
        }?.id ?? "en"
    }
}
