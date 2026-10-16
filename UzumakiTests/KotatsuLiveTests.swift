import Foundation
import SwiftData
import Testing
@testable import Uzumaki

/// Exercises the full Kotatsu path the app uses — Services bootstrap → registry →
/// source → host → page bytes — against the real parser host.
///
/// This is everything except the SwiftUI layer, so a passing run means the feature
/// works end to end and only presentation remains unverified.
@Suite(
    "Kotatsu sources (live)",
    .enabled(if: ProcessInfo.processInfo.environment["UZUMAKI_LIVE_TESTS"] == "1")
)
@MainActor
struct KotatsuLiveTests {
    private func makeServices() throws -> (Services, ModelContainer) {
        let configuration = try #require(
            KotatsuHostLocator.resolve(),
            "Build ParserHost/ (./gradlew fatJar) and install a JDK 17 to run this test"
        )
        let container = try PersistenceContainer.make(inMemory: true)
        let services = Services(
            container: container,
            kotatsuConfiguration: configuration
        )
        return (services, container)
    }

    private func makeSettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "uzumaki.kotatsu.\(UUID().uuidString)")!)
    }

    @Test("Bootstrapping registers every source, with only the verified ones on", .timeLimit(.minutes(2)))
    func registration() async throws {
        let (services, container) = try makeServices()
        _ = container

        await services.bootstrapSources(using: makeSettings())

        let all = await services.registry.all()
        let kotatsu = all.filter { $0.provider == .kotatsuHost }
        #expect(kotatsu.count > 1000, "the whole catalogue should be registered: \(services.kotatsuUnavailableReason ?? "no reason recorded")")
        #expect(services.kotatsuUnavailableReason == nil)
        #expect(kotatsu.allSatisfy { !$0.isBuiltIn })
        #expect(kotatsu.contains { $0.id == "kotatsu.MANGAPILL" })

        // Only the measured-good set is on before any check runs; everything else
        // waits for the user (or the bulk check) to decide.
        let enabled = kotatsu.filter(\.isEnabled)
        #expect(enabled.count == KotatsuCatalog.enabledByDefault.count)
        #expect(enabled.allSatisfy { KotatsuCatalog.isEnabledByDefault($0.id.replacingOccurrences(of: "kotatsu.", with: "")) })

        // And the app's ordinary path can reach one of them.
        let source = try #require(await services.registry.source(id: "kotatsu.MANGAPILL"))
        #expect(source.name == "MangaPill")

        // The test host is killed abruptly by the runner, so stop the JVM here
        // rather than leaving it behind.
        await services.kotatsuHost?.shutdown()
    }

    @Test("Browse, details, chapters and page images work end to end", .timeLimit(.minutes(4)))
    func endToEnd() async throws {
        let (services, container) = try makeServices()
        _ = container
        await services.bootstrapSources(using: makeSettings())

        let source = try #require(await services.registry.source(id: "kotatsu.MANGAPILL"))

        // Browse.
        let results = try await source.search("berserk", page: 0, filters: [])
        #expect(!results.items.isEmpty, "expected search results")

        let manga = try #require(results.items.first)
        #expect(!manga.title.isEmpty)

        // Covers are routed through the host, not fetched directly.
        let cover = try #require(manga.coverURL, "expected a cover URL")
        #expect(HostImageURL.isHostImage(cover), "covers must be wrapped for host fetching")

        // Details and chapters (the concurrent pair MangaDetailModel issues).
        async let details = source.mangaDetails(id: manga.mangaId)
        async let chapters = source.chapters(mangaId: manga.mangaId)
        let (loaded, list) = try await (details, chapters)

        #expect(!loaded.title.isEmpty)
        #expect(!list.isEmpty, "expected chapters")
        #expect(list.first?.chapterId.isEmpty == false)

        // Pages.
        let chapter = try #require(list.first)
        // These are live third-party sites and CDNs throttle; one retry keeps a
        // momentary hiccup from reading as a product failure.
        let pages: [Page]
        do {
            pages = try await source.pages(chapterId: chapter.chapterId)
        } catch {
            pages = try await source.pages(chapterId: chapter.chapterId)
        }
        #expect(!pages.isEmpty, "expected pages")
        #expect(pages.allSatisfy { HostImageURL.isHostImage($0.url) })

        // And the real bytes, through the same ImagePipeline the reader uses.
        let image = try await services.images.image(for: pages[0], maxPixelSize: 1200)
        #expect(image.width > 100)
        #expect(image.height > 100)

        await services.kotatsuHost?.shutdown()
    }

    @Test("A Kotatsu cover loads through the image pipeline", .timeLimit(.minutes(3)))
    func coverImage() async throws {
        let (services, container) = try makeServices()
        _ = container
        await services.bootstrapSources(using: makeSettings())

        let source = try #require(await services.registry.source(id: "kotatsu.MANGAPILL"))
        let results = try await source.search("berserk", page: 0, filters: [])
        let manga = try #require(results.items.first)
        let cover = try #require(manga.coverURL)

        let image = try await services.images.image(for: cover, maxPixelSize: 400)
        #expect(image.width > 50)

        await services.kotatsuHost?.shutdown()
    }

    @Test("An unavailable host degrades instead of failing the app", .timeLimit(.minutes(1)))
    func gracefulDegradation() async throws {
        let container = try PersistenceContainer.make(inMemory: true)
        // No host: simulates a machine without Java.
        let services = Services(container: container, kotatsuConfiguration: nil)

        await services.bootstrapSources(using: makeSettings())

        let all = await services.registry.all()
        #expect(all.allSatisfy { $0.provider != .kotatsuHost })
        #expect(services.kotatsuUnavailableReason != nil, "the UI needs a reason to show")
    }
}
