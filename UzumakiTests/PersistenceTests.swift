import Foundation
import SwiftData
import Testing
@testable import Uzumaki

@Suite("Persistence", .serialized)
@MainActor
struct PersistenceTests {
    /// The container is returned (not just its context) because the store must
    /// outlive the context for the whole test.
    private func inMemoryContainer() throws -> ModelContainer {
        try PersistenceContainer.make(inMemory: true)
    }

    private func sampleManga(id: String = "m1", title: String = "Test Manga") -> Manga {
        Manga(
            sourceId: "org.mangadex",
            mangaId: id,
            title: title,
            coverURL: URL(string: "https://uploads.mangadex.org/covers/\(id)/c.jpg.512.jpg"),
            author: "Author",
            status: .ongoing,
            genres: ["Action"]
        )
    }

    @Test("Adding to the library is idempotent and refreshes metadata")
    func addIsIdempotent() throws {
        let container = try inMemoryContainer()
        let library = LibraryStore(context: container.mainContext)

        try library.add(sampleManga(title: "First"))
        try library.add(sampleManga(title: "Renamed"))

        let entries = try library.allEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.title == "Renamed")
        #expect(try library.contains(sourceId: "org.mangadex", mangaId: "m1"))
    }

    @Test("Favourites and categories round-trip")
    func favouritesAndCategories() throws {
        let container = try inMemoryContainer()
        let library = LibraryStore(context: container.mainContext)

        let entry = try library.add(sampleManga())
        try library.toggleFavorite(entry)
        #expect(try library.favorites().count == 1)

        let category = try library.createCategory(named: "Reading")
        try library.setCategories([category], for: entry)
        #expect(entry.categories.map(\.name) == ["Reading"])
        #expect(library.entries(in: category).count == 1)

        try library.deleteCategory(category)
        #expect(try library.allCategories().isEmpty)
    }

    @Test("Reading progress is recorded and completes on the last page")
    func progressLifecycle() throws {
        let container = try inMemoryContainer()
        let progress = ProgressStore(context: container.mainContext)

        try progress.update(
            sourceId: "org.mangadex", mangaId: "m1", chapterId: "c1",
            chapterNumber: 1, chapterTitle: "Chapter 1", pageIndex: 3, totalPages: 20
        )
        let mid = try progress.record(sourceId: "org.mangadex", mangaId: "m1", chapterId: "c1")
        #expect(mid?.status == .reading)
        #expect(mid?.lastPageIndex == 3)

        try progress.update(
            sourceId: "org.mangadex", mangaId: "m1", chapterId: "c1",
            chapterNumber: 1, chapterTitle: "Chapter 1", pageIndex: 19, totalPages: 20
        )
        let done = try progress.record(sourceId: "org.mangadex", mangaId: "m1", chapterId: "c1")
        #expect(done?.status == .completed)
        #expect(try progress.readChapterIds(sourceId: "org.mangadex", mangaId: "m1") == ["c1"])
    }

    @Test("Bookmarks toggle on and off and keep their titles")
    func bookmarkToggle() throws {
        let container = try inMemoryContainer()
        let bookmarks = BookmarkStore(context: container.mainContext)

        let added = try bookmarks.toggle(
            sourceId: "org.mangadex",
            mangaId: "m1",
            mangaTitle: "Test Manga",
            chapterId: "c1",
            chapterTitle: "Chapter 1",
            pageIndex: 5
        )
        #expect(added)
        #expect(try bookmarks.contains(sourceId: "org.mangadex", mangaId: "m1", chapterId: "c1", pageIndex: 5))

        let stored = try bookmarks.bookmarks(sourceId: "org.mangadex", mangaId: "m1")
        #expect(stored.count == 1)
        #expect(stored.first?.mangaTitle == "Test Manga")
        #expect(stored.first?.chapterTitle == "Chapter 1")
        #expect(stored.first?.pageIndex == 5)
        #expect(stored.first?.manga.title == "Test Manga")

        let removed = try bookmarks.toggle(
            sourceId: "org.mangadex",
            mangaId: "m1",
            mangaTitle: "Test Manga",
            chapterId: "c1",
            chapterTitle: "Chapter 1",
            pageIndex: 5
        )
        #expect(!removed)
        #expect(try bookmarks.all().isEmpty)
    }

    @Test("History keeps a single row per manga and updates it")
    func historyUpsert() throws {
        let container = try inMemoryContainer()
        let history = HistoryStore(context: container.mainContext)
        let manga = sampleManga()

        try history.record(manga: manga, chapter: nil, at: Date(timeIntervalSince1970: 100))
        try history.record(
            manga: manga,
            chapter: Chapter(sourceId: "org.mangadex", mangaId: "m1", chapterId: "c9", number: 9),
            at: Date(timeIntervalSince1970: 200)
        )

        let rows = try history.recent()
        #expect(rows.count == 1)
        #expect(rows.first?.chapterId == "c9")
        #expect(rows.first?.visitedAt == Date(timeIntervalSince1970: 200))
    }

    @Test("Source preferences persist configuration")
    func sourcePreferences() throws {
        let container = try inMemoryContainer()
        let store = SourceStore(context: container.mainContext)

        try store.upsert(sourceId: "org.mangadex", name: "MangaDex", version: "1.0.0", isBuiltIn: true)
        try store.setConfig(["quality": "data-saver", "language": "en"], sourceId: "org.mangadex")
        try store.setEnabled(false, sourceId: "org.mangadex")

        let record = try store.preferences(for: "org.mangadex")
        #expect(record?.config["quality"] == "data-saver")
        #expect(record?.isEnabled == false)
        #expect(try store.enabledSourceIds().isEmpty)
    }

    @Test("Download records track state and byte totals")
    func downloadRecords() throws {
        let container = try inMemoryContainer()
        let store = DownloadStore(context: container.mainContext)

        let record = DownloadRecord(
            sourceId: "org.mangadex", mangaId: "m1", mangaTitle: "Test",
            chapterId: "c1", chapterNumber: 1, totalPages: 10, directoryName: "c1"
        )
        try store.upsert(record)

        try store.update(sourceId: "org.mangadex", mangaId: "m1", chapterId: "c1", state: .completed, downloadedPages: 10, byteCount: 4096)
        let updated = try store.record(sourceId: "org.mangadex", mangaId: "m1", chapterId: "c1")
        #expect(updated?.state == .completed)
        #expect(updated?.progress == 1)
        #expect(try store.totalByteCount() == 4096)
        #expect(try store.completedCount() == 1)
    }

    @Test("Library survives a container reopen (relaunch)")
    func survivesRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uzumaki-relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("library.store")

        do {
            let container = try PersistenceContainer.make(url: storeURL)
            let library = LibraryStore(context: container.mainContext)
            let progress = ProgressStore(context: container.mainContext)

            try library.add(sampleManga(title: "Persisted"))
            try progress.update(
                sourceId: "org.mangadex", mangaId: "m1", chapterId: "c1",
                chapterNumber: 1, chapterTitle: "Chapter 1", pageIndex: 7, totalPages: 30
            )
        }

        // A fresh container over the same file stands in for an app relaunch.
        let reopened = try PersistenceContainer.make(url: storeURL)
        let library = LibraryStore(context: reopened.mainContext)
        let progress = ProgressStore(context: reopened.mainContext)

        #expect(try library.contains(sourceId: "org.mangadex", mangaId: "m1"))
        #expect(try library.allEntries().first?.title == "Persisted")

        let record = try progress.record(sourceId: "org.mangadex", mangaId: "m1", chapterId: "c1")
        #expect(record?.lastPageIndex == 7)
        #expect(record?.status == .reading)
    }
}
