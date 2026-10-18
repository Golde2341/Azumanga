import Foundation
import SwiftUI

/// Identifies a reading session and carries everything the reader needs, so
/// opening a chapter never requires re-fetching the manga's chapter list.
///
/// `Codable` because it is the value of a `WindowGroup`, which lets the reader live
/// in its own window and survive window restoration.
nonisolated struct ReaderSession: Hashable, Identifiable, Sendable, Codable {
    var manga: Manga
    var chapters: [Chapter]
    var chapterId: String
    /// Where to open the chapter, overriding saved progress (used by bookmarks).
    var startPageIndex: Int?

    var id: String { "\(manga.sourceId):\(manga.mangaId):\(chapterId)" }
}

/// Drives the reader: resolves pages, tracks the current page, persists
/// progress, prefetches ahead and moves between chapters.
@MainActor
@Observable
final class ReaderModel {
    let manga: Manga
    private(set) var chapters: [Chapter]
    private(set) var currentChapterIndex: Int

    var pages: [Page] = []
    var currentIndex = 0
    var isLoading = true
    var errorMessage: String?

    /// Transient zoom factor applied to the current page (1 = fit).
    var zoom: CGFloat = 1

    private let services: Services
    private let settings: SettingsStore
    private let startPageIndex: Int?
    /// True when the reader was opened without a chapter list (library Force Touch,
    /// bookmarks, Downloads). The list is fetched in the background so next/previous
    /// chapters and continuous reading work without delaying the pages.
    private let needsChapterList: Bool
    private var hasRequestedChapterList = false
    private var saveTask: Task<Void, Never>?

    init(
        manga: Manga,
        chapters: [Chapter],
        startChapterId: String,
        startPageIndex: Int? = nil,
        services: Services,
        settings: SettingsStore
    ) {
        self.manga = manga
        self.startPageIndex = startPageIndex
        self.needsChapterList = chapters.isEmpty
        if chapters.isEmpty {
            // Opened directly (for example from Downloads): rebuild what we know
            // about the chapter from the saved progress row.
            let saved = try? services.progressStore.record(
                sourceId: manga.sourceId,
                mangaId: manga.mangaId,
                chapterId: startChapterId
            )
            self.chapters = [Chapter(
                sourceId: manga.sourceId,
                mangaId: manga.mangaId,
                chapterId: startChapterId,
                title: saved?.chapterTitle,
                number: saved?.chapterNumber
            )]
            self.currentChapterIndex = 0
        } else {
            self.chapters = chapters
            self.currentChapterIndex = chapters.firstIndex { $0.chapterId == startChapterId } ?? 0
        }
        self.services = services
        self.settings = settings
    }

    /// Decoded size cap. Larger values look sharper at the cost of memory.
    var renderMaxPixelSize: Int {
        settings.fitMode == .original ? 4096 : 1600
    }

    var chapter: Chapter {
        chapters[min(currentChapterIndex, chapters.count - 1)]
    }

    var chapterCount: Int { chapters.count }

    var hasNextChapter: Bool { currentChapterIndex + 1 < chapters.count }
    var hasPreviousChapter: Bool { currentChapterIndex > 0 }

    var pageProgress: Double {
        guard pages.count > 1 else { return pages.isEmpty ? 0 : 1 }
        return Double(currentIndex) / Double(pages.count - 1)
    }

    /// Chapters hosted elsewhere cannot be served as pages.
    var isExternallyHosted: Bool { chapter.externalURL != nil }

    var chapterLabel: String { chapter.displayName }

    // MARK: - Loading

    func load() async {
        isLoading = true
        errorMessage = nil
        pages = []
        currentIndex = 0
        zoom = 1

        // A reader opened from the library or a bookmark carries no chapter list.
        // Fetch it alongside the pages so the next/previous controls and continuous
        // reading have somewhere to go. Failure leaves the single known chapter.
        startChapterListLoadIfNeeded()

        if isExternallyHosted {
            isLoading = false
            errorMessage = "This chapter is hosted on an external site and has no readable pages here."
            return
        }

        // Prefer a completed offline download so reading works without a network.
        if let downloaded = await downloadedPages(), !downloaded.isEmpty {
            pages = downloaded
            restoreProgress()
            isLoading = false
            return
        }

        guard let source = await services.registry.source(id: manga.sourceId) else {
            isLoading = false
            errorMessage = "The source for this manga is no longer available."
            return
        }

        do {
            let fetched = try await source.pages(chapterId: chapter.chapterId)
            pages = fetched
            restoreProgress()
            isLoading = false
            prefetchAhead()
        } catch is CancellationError {
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = userFacingMessage(for: error)
        }
    }

    /// Resolves the full chapter list for a reader opened without one, without
    /// delaying the pages. When it arrives, the model's chapter index is moved to the
    /// chapter being read, which enables next/previous and the continuous stream.
    private func startChapterListLoadIfNeeded() {
        guard needsChapterList, !hasRequestedChapterList else { return }
        hasRequestedChapterList = true

        let startingChapterId = chapter.chapterId
        Task { [weak self] in
            await self?.loadChapterList(startingAt: startingChapterId)
        }
    }

    private func loadChapterList(startingAt chapterId: String) async {
        guard let source = await services.registry.source(id: manga.sourceId) else { return }
        guard let fetched = try? await source.chapters(mangaId: manga.mangaId),
              !fetched.isEmpty
        else { return }

        let ordered = Chapter.readingOrder(fetched)
        guard let index = ordered.firstIndex(where: { $0.chapterId == chapterId }),
              chapter.chapterId == chapterId
        else { return }

        // Move the index before publishing the list: `chapter` clamps to the old
        // single-chapter array in between, so the chapter being read never changes
        // identity while the view is observing the update.
        currentChapterIndex = index
        chapters = ordered
    }

    private func downloadedPages() async -> [Page]? {
        await downloadedPages(for: chapter)
    }

    private func downloadedPages(for chapter: Chapter) async -> [Page]? {
        let record = try? services.downloadStore.record(
            sourceId: manga.sourceId,
            mangaId: manga.mangaId,
            chapterId: chapter.chapterId
        )
        guard record?.state == .completed else { return nil }
        return await services.downloads.localPages(job(for: chapter))
    }

    private func job(for chapter: Chapter) -> DownloadJob {
        DownloadJob(
            sourceId: manga.sourceId,
            mangaId: manga.mangaId,
            mangaTitle: manga.title,
            chapterId: chapter.chapterId,
            chapterTitle: chapter.title,
            chapterNumber: chapter.number
        )
    }

    var job: DownloadJob { job(for: chapter) }

    /// Resolves a chapter's pages without making it current. The continuous vertical
    /// reader uses this to put the next episode below the one being read.
    func loadPages(forChapterAt index: Int) async -> [Page]? {
        guard chapters.indices.contains(index) else { return nil }
        return await loadPages(forChapterId: chapters[index].chapterId)
    }

    /// Resolves a chapter by id so a caller holding a stable chapter id is not
    /// affected by the chapter list arriving or being reordered mid-fetch.
    func loadPages(forChapterId chapterId: String) async -> [Page]? {
        guard let chapter = chapters.first(where: { $0.chapterId == chapterId }),
              chapter.externalURL == nil
        else { return nil }

        if let downloaded = await downloadedPages(for: chapter), !downloaded.isEmpty {
            return downloaded
        }
        guard let source = await services.registry.source(id: manga.sourceId) else { return nil }
        return try? await source.pages(chapterId: chapter.chapterId)
    }

    /// Makes an already-loaded chapter current, without reloading or touching the
    /// scroll position. Called as the continuous reader crosses a chapter boundary.
    func enterChapter(index: Int, pages: [Page], pageIndex: Int) {
        guard chapters.indices.contains(index), !pages.isEmpty else { return }

        if index != currentChapterIndex || self.pages != pages {
            // Save where the previous episode was left before its state is replaced.
            flushProgress()
        }
        currentChapterIndex = index
        if self.pages != pages {
            self.pages = pages
        }
        currentIndex = min(max(0, pageIndex), pages.count - 1)
        scheduleSave()
        prefetchAhead()
    }

    private func restoreProgress() {
        if let startPageIndex {
            currentIndex = min(max(0, startPageIndex), max(0, pages.count - 1))
            return
        }
        guard let record = try? services.progressStore.record(
            sourceId: manga.sourceId,
            mangaId: manga.mangaId,
            chapterId: chapter.chapterId
        ) else { return }
        guard record.status != .completed else { return }
        currentIndex = min(record.lastPageIndex, max(0, pages.count - 1))
    }

    // MARK: - Bookmarks

    /// The bookmark store is not observable, so changing a bookmark would not
    /// otherwise invalidate views that read `isCurrentPageBookmarked`.
    private(set) var bookmarkRevision = 0

    var isCurrentPageBookmarked: Bool {
        _ = bookmarkRevision
        guard !pages.isEmpty else { return false }
        return (try? services.bookmarkStore.containsKey(bookmarkKey)) ?? false
    }

    private var bookmarkKey: String {
        "\(manga.sourceId):\(manga.mangaId):\(chapter.chapterId):\(currentIndex)"
    }

    func toggleBookmark() {
        guard !pages.isEmpty else { return }
        _ = try? services.bookmarkStore.toggle(
            sourceId: manga.sourceId,
            mangaId: manga.mangaId,
            mangaTitle: manga.title,
            chapterId: chapter.chapterId,
            chapterTitle: chapter.displayName,
            pageIndex: currentIndex
        )
        bookmarkRevision &+= 1
    }

    // MARK: - Navigation

    func goToPage(_ index: Int, save: Bool = true, resetZoom: Bool = true) {
        guard !pages.isEmpty else { return }
        let clamped = min(max(0, index), pages.count - 1)
        guard clamped != currentIndex else { return }
        currentIndex = clamped
        if resetZoom { zoom = 1 }
        if save { scheduleSave() }
        prefetchAhead()
    }

    func nextPage() {
        if currentIndex + 1 < pages.count {
            goToPage(currentIndex + 1)
        } else if hasNextChapter {
            Task { await goToChapter(index: currentChapterIndex + 1) }
        }
    }

    func previousPage() {
        if currentIndex > 0 {
            goToPage(currentIndex - 1)
        } else if hasPreviousChapter {
            Task { await goToChapter(index: currentChapterIndex - 1) }
        }
    }

    func goToChapter(index: Int) async {
        guard chapters.indices.contains(index), index != currentChapterIndex else { return }
        flushProgress()
        currentChapterIndex = index
        await load()
    }

    func goToChapter(id: String) async {
        guard let index = chapters.firstIndex(where: { $0.chapterId == id }) else { return }
        await goToChapter(index: index)
    }

    // MARK: - Zoom

    /// Zoom range for the reader. Below 1 the page shrinks inside the window,
    /// leaving bars around it; above 1 it grows past the window.
    static let minZoom: CGFloat = 0.5
    static let maxZoom: CGFloat = 5

    func setZoom(_ value: CGFloat) {
        zoom = min(max(Self.minZoom, value), Self.maxZoom)
    }

    func zoomIn() { setZoom(zoom + 0.5) }
    func zoomOut() { setZoom(zoom - 0.5) }
    func resetZoom() { zoom = 1 }

    // MARK: - Prefetch

    private func prefetchAhead() {
        guard !pages.isEmpty else { return }
        let distance = settings.prefetchDistance
        guard distance > 0 else { return }

        let lower = max(0, currentIndex - 1)
        let upper = min(pages.count - 1, currentIndex + distance)
        guard lower <= upper else { return }
        let urls = (lower...upper).map { pages[$0].url }
        let size = renderMaxPixelSize
        Task { await services.images.prefetch(urls: urls, maxPixelSize: size) }
    }

    /// Warms the opening pages of an episode that was appended to the continuous
    /// reader, so crossing the break does not land on a placeholder.
    func prefetchFirstPages(of pages: [Page], count: Int = 2) {
        guard !pages.isEmpty else { return }
        let urls = pages.prefix(max(1, count)).map(\.url)
        let size = renderMaxPixelSize
        Task { await services.images.prefetch(urls: urls, maxPixelSize: size) }
    }

    // MARK: - Progress

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.persistProgress()
        }
    }

    /// Writes progress immediately; called when leaving the reader.
    func flushProgress() {
        saveTask?.cancel()
        persistProgress()
    }

    private func persistProgress() {
        guard !pages.isEmpty else { return }
        let total = pages.count
        let index = currentIndex
        _ = try? services.progressStore.update(
            sourceId: manga.sourceId,
            mangaId: manga.mangaId,
            chapterId: chapter.chapterId,
            chapterNumber: chapter.number,
            chapterTitle: chapter.displayName,
            pageIndex: index,
            totalPages: total
        )
        _ = try? services.historyStore.record(manga: manga, chapter: chapter)
        if let entry = try? services.libraryStore.entry(sourceId: manga.sourceId, mangaId: manga.mangaId) {
            _ = try? services.libraryStore.updateReadingPointer(
                entry,
                chapterId: chapter.chapterId,
                chapterNumber: chapter.number,
                chapterTitle: chapter.displayName
            )
        }
    }

    func markCurrentChapterRead() {
        try? services.progressStore.markRead(chapter)
    }

    /// Marks a chapter finished while the continuous reader crosses it. The previous
    /// chapter's page progress is flushed separately, so an episode read through the
    /// scroll stream still ends up completed.
    func markChapterRead(at index: Int) {
        guard chapters.indices.contains(index) else { return }
        try? services.progressStore.markRead(chapters[index])
    }

    func markCurrentChapterUnread() {
        try? services.progressStore.markUnread(chapter)
    }
}
