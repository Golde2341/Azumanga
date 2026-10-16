import Foundation
import SwiftData
import Testing
@testable import Uzumaki

/// A source whose pages live on a stub host, so downloads can be exercised
/// without touching the network.
private actor ImageSource: MangaSource {
    nonisolated let id = "test.images"
    nonisolated let name = "Images"
    nonisolated let version = "1.0.0"
    nonisolated let language = "en"
    nonisolated let isBuiltIn = false
    nonisolated let capabilities: Set<SourceCapability> = [.chapters, .pages]

    private let host: String
    private let pageCount: Int
    private(set) var pageRequests = 0

    init(host: String, pageCount: Int) {
        self.host = host
        self.pageCount = pageCount
    }

    func search(_ query: String, page: Int, filters: [MangaFilterValue]) async throws -> PagedResult<Manga> {
        PagedResult(items: [], hasNextPage: false)
    }

    func mangaDetails(id: String) async throws -> Manga { Manga(sourceId: id, mangaId: id, title: "Test") }
    func chapters(mangaId: String) async throws -> [Chapter] { [] }

    func pages(chapterId: String) async throws -> [Page] {
        pageRequests += 1
        return (0..<pageCount).map { index in
            Page(index: index, url: URL(string: "https://\(host)/\(chapterId)/\(index).png")!)
        }
    }

    var requests: Int { pageRequests }
}

@Suite("Downloads", .serialized)
@MainActor
struct DownloadManagerTests {
    private func makeTempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("uzumaki-downloads-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeServices(root: URL) throws -> (Services, ModelContainer) {
        let container = try PersistenceContainer.make(inMemory: true)
        let client = HTTPClient(
            session: StubURLProtocol.makeSession(),
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: 0.01, maxDelay: 0.02, jitter: 0)
        )
        let services = Services(
            container: container,
            http: client,
            downloadDirectories: DownloadDirectories(root: root)
        )
        return (services, container)
    }

    private func job(chapterId: String = "c1") -> DownloadJob {
        DownloadJob(
            sourceId: "test.images",
            mangaId: "m1",
            mangaTitle: "Test Manga",
            chapterId: chapterId,
            chapterTitle: "Chapter 1",
            chapterNumber: 1
        )
    }

    @Test("Downloads every page and reports progress")
    func downloadsPages() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let host = StubURLProtocol.makeHost("dl")
        StubURLProtocol.setHandler(for: host) { _ in
            StubURLProtocol.Response(statusCode: 200, body: makePNGData(width: 40, height: 60))
        }

        let (services, container) = try makeServices(root: root)
        _ = container
        await services.registry.register(ImageSource(host: host, pageCount: 4))

        let updates = Counter()
        let lastTotal = Counter()
        let outcome = try await services.downloads.run(job()) { progress in
            _ = updates.increment()
            lastTotal.set(progress.totalPages)
        }

        #expect(outcome.pageCount == 4)
        #expect(outcome.byteCount > 0)
        #expect(updates.value >= 5) // one initial update plus one per page
        #expect(lastTotal.value == 4)
        #expect(StubURLProtocol.requests(for: host).count == 4)

        let pages = await services.downloads.localPages(job())
        #expect(pages.count == 4)
        #expect(pages.map(\.index) == [0, 1, 2, 3])
        #expect(pages.allSatisfy { $0.url.isFileURL })
        #expect(pages.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    }

    @Test("Re-running resumes instead of re-downloading what is on disk")
    func resumable() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let host = StubURLProtocol.makeHost("dl-resume")
        StubURLProtocol.setHandler(for: host) { _ in
            StubURLProtocol.Response(statusCode: 200, body: makePNGData(width: 20, height: 20))
        }

        let (services, container) = try makeServices(root: root)
        _ = container
        await services.registry.register(ImageSource(host: host, pageCount: 3))

        _ = try await services.downloads.run(job()) { _ in }
        #expect(StubURLProtocol.requests(for: host).count == 3)

        // Delete one page and run again: only the missing page is fetched.
        let firstRun = await services.downloads.localPages(job())
        try FileManager.default.removeItem(at: firstRun[1].url)

        // Re-registering also clears the recorded requests.
        StubURLProtocol.setHandler(for: host) { _ in
            StubURLProtocol.Response(statusCode: 200, body: makePNGData(width: 20, height: 20))
        }
        _ = try await services.downloads.run(job()) { _ in }
        #expect(StubURLProtocol.requests(for: host).count == 1)

        let secondRun = await services.downloads.localPages(job())
        #expect(secondRun.count == 3)
    }

    @Test("Cancelling stops the download and keeps what was fetched")
    func cancellation() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let host = StubURLProtocol.makeHost("dl-cancel")
        StubURLProtocol.setHandler(for: host) { _ in
            // Slow enough that the download is still in flight when cancelled.
            Thread.sleep(forTimeInterval: 0.01)
            return StubURLProtocol.Response(statusCode: 200, body: makePNGData(width: 20, height: 20))
        }

        let (services, container) = try makeServices(root: root)
        _ = container
        await services.registry.register(ImageSource(host: host, pageCount: 400))

        let task = Task {
            try await services.downloads.run(job()) { _ in }
        }
        try await Task.sleep(for: .milliseconds(120))
        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            Issue.record("expected the download to be cancelled")
        case .failure(let error):
            #expect(error is CancellationError)
        }

        let downloaded = await services.downloads.localPages(job())
        #expect(downloaded.count < 400)
    }

    @Test("Deleting removes the downloaded files")
    func deleteFiles() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let host = StubURLProtocol.makeHost("dl-delete")
        StubURLProtocol.setHandler(for: host) { _ in
            StubURLProtocol.Response(statusCode: 200, body: makePNGData(width: 20, height: 20))
        }

        let (services, container) = try makeServices(root: root)
        _ = container
        await services.registry.register(ImageSource(host: host, pageCount: 2))

        _ = try await services.downloads.run(job()) { _ in }
        let beforeDelete = await services.downloads.byteCount(job())
        #expect(beforeDelete > 0)

        await services.downloads.deleteFiles(job())
        let afterDelete = await services.downloads.localPages(job())
        let size = await services.downloads.totalSize()
        #expect(afterDelete.isEmpty)
        #expect(size == 0)
    }

    @Test("Readers prefer a completed download and never ask the source")
    func offlineReading() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let host = StubURLProtocol.makeHost("dl-offline")
        StubURLProtocol.setHandler(for: host) { _ in
            StubURLProtocol.Response(statusCode: 200, body: makePNGData(width: 40, height: 60))
        }

        let (services, container) = try makeServices(root: root)
        _ = container
        let source = ImageSource(host: host, pageCount: 3)
        await services.registry.register(source)

        let outcome = try await services.downloads.run(job()) { _ in }
        let downloadedPages = await services.downloads.localPages(job())
        #expect(downloadedPages.count == 3)

        try services.downloadStore.upsert(
            DownloadRecord(
                sourceId: "test.images",
                mangaId: "m1",
                mangaTitle: "Test Manga",
                chapterId: "c1",
                chapterTitle: "Chapter 1",
                chapterNumber: 1,
                state: .completed,
                downloadedPages: outcome.pageCount,
                totalPages: outcome.pageCount,
                byteCount: outcome.byteCount,
                directoryName: "test.images/m1/c1"
            )
        )

        // The download itself asked for the page list once; reading must not.
        let requestsAfterDownload = await source.requests

        let settings = SettingsStore(defaults: UserDefaults(suiteName: "uzumaki.dl.\(UUID().uuidString)")!)
        settings.prefetchDistance = 0

        let model = ReaderModel(
            manga: Manga(sourceId: "test.images", mangaId: "m1", title: "Test Manga"),
            chapters: [Chapter(sourceId: "test.images", mangaId: "m1", chapterId: "c1", number: 1)],
            startChapterId: "c1",
            services: services,
            settings: settings
        )
        await model.load()

        #expect(model.errorMessage == nil)
        #expect(model.pages.count == 3)
        #expect(model.pages.allSatisfy { $0.url.isFileURL })

        // No further page-list request: this is genuinely offline.
        let requestsAfterReading = await source.requests
        #expect(requestsAfterReading == requestsAfterDownload)
    }

    @Test("An interrupted download shows as paused rather than running")
    func staleRecordsAreReconciled() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let (services, container) = try makeServices(root: root)
        _ = container

        try services.downloadStore.upsert(
            DownloadRecord(
                sourceId: "test.images",
                mangaId: "m1",
                mangaTitle: "Test Manga",
                chapterId: "c1",
                state: .downloading,
                directoryName: "test.images/m1/c1"
            )
        )

        // Rebuilding the model stands in for relaunching the app.
        let model = DownloadsModel(services: services)
        let record = try services.downloadStore.record(sourceId: "test.images", mangaId: "m1", chapterId: "c1")
        #expect(model.records.count == 1)
        #expect(record?.state == .paused)
    }

    @Test("Path components from providers are sanitised")
    func pathSanitising() {
        #expect(DownloadDirectories.sanitize("abc-123_XYZ.png") == "abc-123_XYZ.png")
        #expect(DownloadDirectories.sanitize("../../etc") == ".._.._etc")
        #expect(DownloadDirectories.sanitize("..") == "_")
        #expect(DownloadDirectories.sanitize("a/b") == "a_b")
        #expect(DownloadDirectories.sanitize("") == "_")
        #expect(DownloadDirectories.sanitize(String(repeating: "x", count: 300)).count == 96)

        let directories = DownloadDirectories(root: URL(fileURLWithPath: "/tmp/root"))
        let directory = directories.chapterDirectory(sourceId: "../evil", mangaId: "m/1", chapterId: "..")
        #expect(!directory.path.contains("../"))
        #expect(directory.path.hasPrefix("/tmp/root/"))
    }
}
