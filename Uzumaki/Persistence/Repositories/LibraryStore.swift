import Foundation
import SwiftData

nonisolated enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case dateAddedDescending
    case titleAscending
    case lastReadDescending

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dateAddedDescending: "Recently Added"
        case .titleAscending: "Title"
        case .lastReadDescending: "Recently Read"
        }
    }
}

/// Reads and mutates the user's library. Views never touch `ModelContext`
/// directly — all persistence goes through a store.
@MainActor
final class LibraryStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Queries

    func allEntries(sortedBy sort: LibrarySort = .dateAddedDescending) throws -> [LibraryEntry] {
        var descriptor = FetchDescriptor<LibraryEntry>()
        switch sort {
        case .dateAddedDescending:
            descriptor.sortBy = [SortDescriptor(\LibraryEntry.dateAdded, order: .reverse)]
        case .titleAscending:
            descriptor.sortBy = [SortDescriptor(\LibraryEntry.title, order: .forward)]
        case .lastReadDescending:
            descriptor.sortBy = [SortDescriptor(\LibraryEntry.lastReadAt, order: .reverse)]
        }
        return try context.fetch(descriptor)
    }

    func favorites() throws -> [LibraryEntry] {
        let descriptor = FetchDescriptor<LibraryEntry>(
            predicate: #Predicate { $0.isFavorite },
            sortBy: [SortDescriptor(\LibraryEntry.title, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    func entry(sourceId: String, mangaId: String) throws -> LibraryEntry? {
        let key = "\(sourceId):\(mangaId)"
        var descriptor = FetchDescriptor<LibraryEntry>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func contains(sourceId: String, mangaId: String) throws -> Bool {
        try entry(sourceId: sourceId, mangaId: mangaId) != nil
    }

    func entries(in category: MangaCategory, sortedBy sort: LibrarySort = .titleAscending) -> [LibraryEntry] {
        category.entries.sorted { lhs, rhs in
            switch sort {
            case .titleAscending: lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            case .dateAddedDescending: lhs.dateAdded > rhs.dateAdded
            case .lastReadDescending: (lhs.lastReadAt ?? .distantPast) > (rhs.lastReadAt ?? .distantPast)
            }
        }
    }

    // MARK: - Mutations

    /// Adds a manga to the library, or refreshes it if already present.
    @discardableResult
    func add(_ manga: Manga) throws -> LibraryEntry {
        if let existing = try entry(sourceId: manga.sourceId, mangaId: manga.mangaId) {
            existing.refresh(with: manga)
            try save()
            return existing
        }
        let entry = LibraryEntry(
            sourceId: manga.sourceId,
            mangaId: manga.mangaId,
            title: manga.title,
            coverURLString: manga.coverURL?.absoluteString,
            author: manga.author,
            artist: manga.artist,
            status: manga.status,
            contentRating: manga.contentRating,
            genres: manga.genres
        )
        context.insert(entry)
        try save()
        return entry
    }

    func remove(_ entry: LibraryEntry) throws {
        context.delete(entry)
        try save()
    }

    func remove(sourceId: String, mangaId: String) throws {
        if let entry = try entry(sourceId: sourceId, mangaId: mangaId) {
            try remove(entry)
        }
    }

    func toggleFavorite(_ entry: LibraryEntry) throws {
        entry.isFavorite.toggle()
        try save()
    }

    func recordOpened(_ entry: LibraryEntry, at date: Date = Date()) throws {
        entry.lastOpenedAt = date
        try save()
    }

    func updateReadingPointer(
        _ entry: LibraryEntry,
        chapterId: String,
        chapterNumber: Double?,
        chapterTitle: String?,
        at date: Date = Date()
    ) throws {
        entry.lastReadChapterId = chapterId
        entry.lastReadChapterNumber = chapterNumber
        entry.lastReadChapterTitle = chapterTitle
        entry.lastReadAt = date
        try save()
    }

    // MARK: - Categories

    func allCategories() throws -> [MangaCategory] {
        try context.fetch(
            FetchDescriptor<MangaCategory>(sortBy: [SortDescriptor(\MangaCategory.order, order: .forward)])
        )
    }

    @discardableResult
    func createCategory(named name: String) throws -> MangaCategory {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextOrder = (try allCategories().map(\.order).max() ?? -1) + 1
        let category = MangaCategory(name: trimmed, order: nextOrder)
        context.insert(category)
        try save()
        return category
    }

    func renameCategory(_ category: MangaCategory, to name: String) throws {
        category.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try save()
    }

    func deleteCategory(_ category: MangaCategory) throws {
        context.delete(category)
        try save()
    }

    func setCategories(_ categories: [MangaCategory], for entry: LibraryEntry) throws {
        entry.categories = categories
        try save()
    }

    // MARK: - Saving

    func save() throws {
        if context.hasChanges {
            try context.save()
        }
    }
}
