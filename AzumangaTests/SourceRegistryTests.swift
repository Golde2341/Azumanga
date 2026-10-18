import Foundation
import Testing
@testable import Azumanga

/// Minimal stand-in source for registry tests.
private actor StubSource: MangaSource {
    nonisolated let id: String
    nonisolated let name: String
    nonisolated let version: String
    nonisolated let language: String
    nonisolated let isBuiltIn: Bool
    nonisolated let capabilities: Set<SourceCapability>

    init(id: String, name: String, isBuiltIn: Bool = false, language: String = "en") {
        self.id = id
        self.name = name
        self.version = "1.0.0"
        self.language = language
        self.isBuiltIn = isBuiltIn
        self.capabilities = [.search, .chapters, .pages]
    }

    func search(_ query: String, page: Int, filters: [MangaFilterValue]) async throws -> PagedResult<Manga> {
        PagedResult(items: [], hasNextPage: false)
    }

    func mangaDetails(id: String) async throws -> Manga {
        throw MangaSourceError.notFound
    }

    func chapters(mangaId: String) async throws -> [Chapter] { [] }

    func pages(chapterId: String) async throws -> [Page] { [] }
}

@Suite("SourceRegistry")
struct SourceRegistryTests {
    @Test("Sources register in order and report metadata")
    func registration() async {
        let registry = SourceRegistry()
        await registry.register(StubSource(id: "a", name: "Alpha", isBuiltIn: true))
        await registry.register(StubSource(id: "b", name: "Beta"))

        let all = await registry.all()
        #expect(all.map(\.id) == ["a", "b"])
        #expect(all.first?.isBuiltIn == true)
        #expect(all.last?.isBuiltIn == false)

        let source = await registry.source(id: "b")
        #expect(source?.name == "Beta")
        #expect(await registry.source(id: "missing") == nil)
    }

    @Test("Enablement filters the enabled source set")
    func enablement() async {
        let registry = SourceRegistry()
        await registry.register(StubSource(id: "a", name: "Alpha"))
        await registry.register(StubSource(id: "b", name: "Beta"))

        await registry.setEnabled(false, id: "a")
        #expect(await registry.isEnabled(id: "a") == false)
        #expect(await registry.enabledInfos().map(\.id) == ["b"])
        #expect(await registry.enabledSources().count == 1)

        await registry.setEnabled(true, id: "a")
        #expect(await registry.enabledInfos().map(\.id) == ["a", "b"])
    }

    @Test("Registration honours a supplied enabled set")
    func registrationWithEnabledSet() async {
        let registry = SourceRegistry()
        await registry.register(contentsOf: [
            StubSource(id: "a", name: "Alpha"),
            StubSource(id: "b", name: "Beta"),
        ], enabledIds: ["b"])

        #expect(await registry.enabledInfos().map(\.id) == ["b"])
    }

    @Test("Unregistering removes the source and its enablement")
    func unregister() async {
        let registry = SourceRegistry()
        await registry.register(StubSource(id: "a", name: "Alpha"))

        #expect(await registry.unregister(id: "a"))
        #expect(await registry.unregister(id: "a") == false)
        #expect(await registry.all().isEmpty)
        #expect(await registry.isEnabled(id: "a") == false)
    }
}
