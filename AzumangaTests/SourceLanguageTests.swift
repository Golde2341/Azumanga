import Testing
@testable import Azumanga

@Suite("Source language matching")
@MainActor
struct SourceLanguageTests {
    @Test("Exact locales match case-insensitively")
    func exact() {
        #expect(SourcesModel.sourceLanguage("en", matches: "en"))
        #expect(SourcesModel.sourceLanguage("EN", matches: "en"))
        #expect(SourcesModel.sourceLanguage("pt-BR", matches: "pt-br"))
    }

    @Test("Language-level tags match regional variants")
    func regionalVariants() {
        #expect(SourcesModel.sourceLanguage("pt-BR", matches: "pt"))
        #expect(SourcesModel.sourceLanguage("pt", matches: "pt-BR"))
        #expect(SourcesModel.sourceLanguage("zh-Hans", matches: "zh"))
    }

    @Test("Multilingual sources are included for every language")
    func multilingual() {
        #expect(SourcesModel.sourceLanguage("multi", matches: "es"))
        #expect(SourcesModel.sourceLanguage("all", matches: "ja"))
    }

    @Test("Different languages do not match")
    func differentLanguages() {
        #expect(!SourcesModel.sourceLanguage("en", matches: "es"))
        #expect(!SourcesModel.sourceLanguage("fr", matches: "pt-BR"))
    }

    @Test("Multiple selected languages all participate")
    func multipleLanguages() {
        let selected: Set<String> = ["en", "es"]
        #expect(SourcesModel.sourceLanguage("en", matchesAny: selected))
        #expect(SourcesModel.sourceLanguage("es-419", matchesAny: selected))
        #expect(!SourcesModel.sourceLanguage("fr", matchesAny: selected))
        #expect(!SourcesModel.sourceLanguage("en", matchesAny: []))
    }

    @Test("Parser content types collapse into the welcome categories")
    func contentCategories() {
        #expect(SourceContentType.category(for: "MANGA") == .manga)
        #expect(SourceContentType.category(for: "MANHWA") == .manhwa)
        #expect(SourceContentType.category(for: "COMICS") == .comics)
        #expect(SourceContentType.category(for: "HENTAI") == .hentai)
        #expect(SourceContentType.category(for: "DOUJINSHI") == .hentai)
        #expect(SourceContentType.category(for: "MANHUA") == .misc)
        #expect(SourceContentType.category(for: "NOVEL") == .misc)
        #expect(SourceContentType.category(for: "ONE_SHOT") == .misc)
    }
}
