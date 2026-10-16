import Foundation
import SwiftData
import Testing
@testable import Uzumaki

/// A source that serves a fixed number of pages per chapter.
private actor PageSource: MangaSource {
    nonisolated let id = "test.pages"
    nonisolated let name = "Pages"
    nonisolated let version = "1.0.0"
    nonisolated let language = "en"
    nonisolated let isBuiltIn = false
    nonisolated let capabilities: Set<SourceCapability> = [.chapters, .pages]

    private let pageCount: Int
    private(set) var requestedChapters: [String] = []

    init(pageCount: Int) {
        self.pageCount = pageCount
    }

    func search(_ query: String, page: Int, filters: [MangaFilterValue]) async throws -> PagedResult<Manga> {
        PagedResult(items: [], hasNextPage: false)
    }

    func mangaDetails(id: String) async throws -> Manga {
        Manga(sourceId: id, mangaId: id, title: "Test")
    }

    func chapters(mangaId: String) async throws -> [Chapter] { [] }

    func pages(chapterId: String) async throws -> [Page] {
        requestedChapters.append(chapterId)
        return (0..<pageCount).map { index in
            Page(index: index, url: URL(string: "https://pages.test/\(chapterId)/\(index).png")!)
        }
    }

    var requested: [String] { requestedChapters }
}

@Suite("ReaderModel", .serialized)
@MainActor
struct ReaderModelTests {
    private func makeServices() throws -> (Services, ModelContainer) {
        let container = try PersistenceContainer.make(inMemory: true)
        return (Services(container: container), container)
    }

    private func makeSettings() -> SettingsStore {
        let defaults = UserDefaults(suiteName: "uzumaki.reader.tests.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        // No prefetching in tests: it would attempt real downloads.
        settings.prefetchDistance = 0
        return settings
    }

    private func sampleManga() -> Manga {
        Manga(sourceId: "test.pages", mangaId: "m1", title: "Test Manga")
    }

    private func chapters() -> [Chapter] {
        [
            Chapter(sourceId: "test.pages", mangaId: "m1", chapterId: "c1", number: 1),
            Chapter(sourceId: "test.pages", mangaId: "m1", chapterId: "c2", number: 2),
        ]
    }

    @Test("Loads pages for the requested chapter")
    func loadsPages() async throws {
        let (services, container) = try makeServices()
        _ = container
        let source = PageSource(pageCount: 12)
        await services.registry.register(source)

        let model = ReaderModel(
            manga: sampleManga(),
            chapters: chapters(),
            startChapterId: "c2",
            services: services,
            settings: makeSettings()
        )
        await model.load()

        #expect(model.pages.count == 12)
        #expect(model.chapter.chapterId == "c2")
        #expect(model.currentIndex == 0)
        #expect(await source.requested == ["c2"])
    }

    @Test("Saves progress on page change and restores it on reopen")
    func progressRoundTrip() async throws {
        let (services, container) = try makeServices()
        _ = container
        await services.registry.register(PageSource(pageCount: 30))
        let settings = makeSettings()

        let first = ReaderModel(
            manga: sampleManga(),
            chapters: chapters(),
            startChapterId: "c1",
            services: services,
            settings: settings
        )
        await first.load()
        first.goToPage(9)
        first.flushProgress()

        let record = try services.progressStore.record(sourceId: "test.pages", mangaId: "m1", chapterId: "c1")
        #expect(record?.lastPageIndex == 9)
        #expect(record?.totalPages == 30)
        #expect(record?.status == .reading)

        // Reopening the same chapter resumes on the saved page.
        let second = ReaderModel(
            manga: sampleManga(),
            chapters: chapters(),
            startChapterId: "c1",
            services: services,
            settings: settings
        )
        await second.load()
        #expect(second.currentIndex == 9)
    }

    @Test("Reaching the last page marks the chapter read")
    func completesChapter() async throws {
        let (services, container) = try makeServices()
        _ = container
        await services.registry.register(PageSource(pageCount: 5))

        let model = ReaderModel(
            manga: sampleManga(),
            chapters: chapters(),
            startChapterId: "c1",
            services: services,
            settings: makeSettings()
        )
        await model.load()
        model.goToPage(4)
        model.flushProgress()

        let record = try services.progressStore.record(sourceId: "test.pages", mangaId: "m1", chapterId: "c1")
        #expect(record?.status == .completed)
    }

    @Test("Progress records the reading pointer on the library entry")
    func updatesLibraryPointer() async throws {
        let (services, container) = try makeServices()
        _ = container
        await services.registry.register(PageSource(pageCount: 8))
        try services.libraryStore.add(sampleManga())

        let model = ReaderModel(
            manga: sampleManga(),
            chapters: chapters(),
            startChapterId: "c2",
            services: services,
            settings: makeSettings()
        )
        await model.load()
        model.goToPage(3)
        model.flushProgress()

        let entry = try services.libraryStore.entry(sourceId: "test.pages", mangaId: "m1")
        #expect(entry?.lastReadChapterId == "c2")
        #expect(entry?.lastReadChapterNumber == 2)
        #expect(entry?.lastReadAt != nil)
    }

    @Test("Chapter navigation loads the neighbouring chapter")
    func chapterNavigation() async throws {
        let (services, container) = try makeServices()
        _ = container
        let source = PageSource(pageCount: 4)
        await services.registry.register(source)

        let model = ReaderModel(
            manga: sampleManga(),
            chapters: chapters(),
            startChapterId: "c1",
            services: services,
            settings: makeSettings()
        )
        await model.load()

        #expect(model.hasPreviousChapter == false)
        #expect(model.hasNextChapter)

        await model.goToChapter(index: 1)
        #expect(model.chapter.chapterId == "c2")
        #expect(model.hasPreviousChapter)
        #expect(model.hasNextChapter == false)
        #expect(await source.requested == ["c1", "c2"])
    }

    @Test("Externally hosted chapters surface an error instead of blank pages")
    func externalChapter() async throws {
        let (services, container) = try makeServices()
        _ = container
        await services.registry.register(PageSource(pageCount: 4))

        let external = Chapter(
            sourceId: "test.pages",
            mangaId: "m1",
            chapterId: "ext",
            externalURL: URL(string: "https://elsewhere.test/1")!
        )
        let model = ReaderModel(
            manga: sampleManga(),
            chapters: [external],
            startChapterId: "ext",
            services: services,
            settings: makeSettings()
        )
        await model.load()

        #expect(model.pages.isEmpty)
        #expect(model.errorMessage != nil)
        #expect(model.isExternallyHosted)
    }

    @Test("Zoom is clamped between 1x and 5x")
    func zoomClamping() async throws {
        let (services, container) = try makeServices()
        _ = container
        await services.registry.register(PageSource(pageCount: 2))

        let model = ReaderModel(
            manga: sampleManga(),
            chapters: chapters(),
            startChapterId: "c1",
            services: services,
            settings: makeSettings()
        )
        model.setZoom(0.2)
        #expect(model.zoom == 1)
        model.setZoom(9)
        #expect(model.zoom == 5)
        model.zoomIn()
        #expect(model.zoom == 5)
        model.resetZoom()
        #expect(model.zoom == 1)
    }

    @Test("Missing source reports an error rather than crashing")
    func missingSource() async throws {
        let (services, container) = try makeServices()
        _ = container

        let model = ReaderModel(
            manga: sampleManga(),
            chapters: chapters(),
            startChapterId: "c1",
            services: services,
            settings: makeSettings()
        )
        await model.load()

        #expect(model.errorMessage != nil)
        #expect(model.pages.isEmpty)
    }
}
