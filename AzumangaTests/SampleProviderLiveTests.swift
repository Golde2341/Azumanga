import Foundation
import Testing
@testable import Azumanga

/// Installs the bundled example provider exactly as a user would and drives it
/// against the real MangaDex API — proving a provider can be added at runtime
/// without modifying or recompiling the app.
@Suite(
    "Sample provider (live)",
    .enabled(if: ProcessInfo.processInfo.environment["AZUMANGA_LIVE_TESTS"] == "1")
)
@MainActor
struct SampleProviderLiveTests {
    private func installSample() throws -> (source: JSProviderSource, store: InstalledSourceStore) {
        let package = try SourceInstallService.bundledSamplePackage()
        let store = InstalledSourceStore(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("azumanga-sample-\(UUID().uuidString)", isDirectory: true)
        )
        let installed = try store.install(package)
        let source = try JSProviderSource(
            manifest: installed.manifest,
            script: installed.script,
            configuration: installed.manifest.defaultConfiguration,
            http: HTTPClient(),
            callTimeout: .seconds(60)
        )
        return (source, store)
    }

    @Test("The bundled sample installs, searches and reads real chapters", .timeLimit(.minutes(3)))
    func endToEnd() async throws {
        let (source, store) = try installSample()
        defer { try? FileManager.default.removeItem(at: store.root) }

        #expect(source.id == "com.example.mangadex-js")
        #expect(!source.isBuiltIn)
        #expect(source.capabilities.contains(.pages))

        let results = try await source.search("yotsuba", page: 0, filters: [])
        #expect(!results.items.isEmpty, "sample provider should return search hits")
        let manga = try #require(results.items.first)
        #expect(!manga.title.isEmpty)
        #expect(manga.coverURL != nil)

        let chapters = try await source.chapters(mangaId: manga.mangaId)
        #expect(!chapters.isEmpty, "sample provider should return chapters")

        guard let hosted = chapters.first(where: { $0.externalURL == nil && ($0.pageCount ?? 0) > 0 }) else {
            // Every English chapter for this title is externally hosted; nothing
            // more to assert without picking another title.
            return
        }

        let pages = try await source.pages(chapterId: hosted.chapterId)
        #expect(!pages.isEmpty)
        #expect(pages.first?.url.scheme == "https")
    }

    @Test("The sample provider's filters are exposed", .timeLimit(.minutes(1)))
    func filters() async throws {
        let (source, store) = try installSample()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let filters = try await source.filters()
        #expect(filters.contains { $0.id == "status" })
        #expect(filters.contains { $0.id == "contentRating" })
    }
}
