import Foundation
import Testing
@testable import Uzumaki

/// End-to-end checks against the real MangaDex API. Disabled unless
/// `UZUMAKI_LIVE_TESTS=1` is set, so the default test run stays offline.
@Suite(
    "MangaDex Live",
    .enabled(if: ProcessInfo.processInfo.environment["UZUMAKI_LIVE_TESTS"] == "1")
)
@MainActor
struct MangaDexLiveTests {
    @Test("Searches MangaDex and returns mapped results", .timeLimit(.minutes(1)))
    func search() async throws {
        let source = MangaDexSource()
        let results = try await source.search("yotsuba", page: 0, filters: [])

        #expect(!results.items.isEmpty, "Expected search hits from MangaDex")
        let first = try #require(results.items.first)
        #expect(first.sourceId == "org.mangadex")
        #expect(!first.title.isEmpty)
        #expect(first.coverURL != nil, "Cover art should be resolved from relationships")
    }

    @Test("Fetches details, chapters and readable pages for a hosted chapter", .timeLimit(.minutes(2)))
    func chaptersAndPages() async throws {
        let source = MangaDexSource()
        let results = try await source.popular(page: 0)
        #expect(!results.items.isEmpty)

        // Some manga only link out to external sites, so scan a few until a
        // chapter with real, hosted pages turns up.
        var hostedChapter: Chapter?
        var scannedManga: Manga?
        for manga in results.items.prefix(15) {
            let chapters = try await source.chapters(mangaId: manga.mangaId)
            if let chapter = chapters.first(where: { $0.externalURL == nil && ($0.pageCount ?? 0) > 0 }) {
                hostedChapter = chapter
                scannedManga = manga
                break
            }
        }

        let manga = try #require(scannedManga, "Expected at least one manga with hosted chapters")
        let chapter = try #require(hostedChapter)

        let details = try await source.mangaDetails(id: manga.mangaId)
        #expect(details.mangaId == manga.mangaId)
        #expect(details.sourceId == "org.mangadex")

        let pages = try await source.pages(chapterId: chapter.chapterId)
        #expect(!pages.isEmpty, "Hosted chapter should resolve page URLs")
        #expect(pages.first?.url.scheme == "https")
        #expect(pages.map(\.index) == Array(0..<pages.count))
    }
}
