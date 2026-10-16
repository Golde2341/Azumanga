import Foundation
import SwiftUI

/// Backs the Library section: the saved manga, favourites and categories.
@MainActor
@Observable
final class LibraryModel {
    private let services: Services

    var entries: [LibraryEntry] = []
    var categories: [MangaCategory] = []
    var errorMessage: String?

    var sort: LibrarySort = .dateAddedDescending {
        didSet { reload() }
    }

    init(services: Services) {
        self.services = services
        reload()
    }

    func reload() {
        do {
            entries = try services.libraryStore.allEntries(sortedBy: sort)
            categories = try services.libraryStore.allCategories()
            errorMessage = nil
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    // MARK: - Membership

    func entry(for manga: Manga) -> LibraryEntry? {
        entries.first { $0.key == "\(manga.sourceId):\(manga.mangaId)" }
    }

    func contains(_ manga: Manga) -> Bool {
        entry(for: manga) != nil
    }

    func isFavorite(_ manga: Manga) -> Bool {
        entry(for: manga)?.isFavorite ?? false
    }

    // MARK: - Mutations

    func add(_ manga: Manga) {
        do {
            let entry = try services.libraryStore.add(manga)
            entries = try services.libraryStore.allEntries(sortedBy: sort)
            errorMessage = nil
            _ = entry
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func addOrRemove(_ manga: Manga) {
        if let existing = entry(for: manga) {
            remove(existing)
        } else {
            add(manga)
        }
    }

    func remove(_ entry: LibraryEntry) {
        do {
            try services.libraryStore.remove(entry)
            reload()
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func toggleFavorite(_ entry: LibraryEntry) {
        do {
            try services.libraryStore.toggleFavorite(entry)
            reload()
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func createCategory(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try services.libraryStore.createCategory(named: trimmed)
            categories = try services.libraryStore.allCategories()
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func deleteCategory(_ category: MangaCategory) {
        do {
            try services.libraryStore.deleteCategory(category)
            reload()
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    /// Entries belonging to a category, ordered by the given sort.
    func entries(in category: MangaCategory, sortedBy sort: LibrarySort = .titleAscending) -> [LibraryEntry] {
        services.libraryStore.entries(in: category, sortedBy: sort)
    }

    func setCategories(_ categories: [MangaCategory], for entry: LibraryEntry) {
        do {
            try services.libraryStore.setCategories(categories, for: entry)
            reload()
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func recordOpened(_ entry: LibraryEntry) {
        try? services.libraryStore.recordOpened(entry)
    }

    // MARK: - Progress helpers

    func readChapterIds(for manga: Manga) -> Set<String> {
        (try? services.progressStore.readChapterIds(sourceId: manga.sourceId, mangaId: manga.mangaId)) ?? []
    }

    func progress(for chapter: Chapter) -> ReadingProgressRecord? {
        try? services.progressStore.record(
            sourceId: chapter.sourceId,
            mangaId: chapter.mangaId,
            chapterId: chapter.chapterId
        )
    }

    func recentlyRead(limit: Int = 20) -> [ReadingProgressRecord] {
        (try? services.progressStore.recentlyRead(limit: limit)) ?? []
    }

    func history(limit: Int = 30) -> [HistoryRecord] {
        (try? services.historyStore.recent(limit: limit)) ?? []
    }

    func bookmarks() -> [BookmarkRecord] {
        (try? services.bookmarkStore.all()) ?? []
    }

    func removeBookmark(_ bookmark: BookmarkRecord) throws {
        try services.bookmarkStore.remove(bookmark)
    }

    func removeHistory(_ record: HistoryRecord) throws {
        try services.historyStore.remove(record)
    }
}
