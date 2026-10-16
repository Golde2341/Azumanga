import Foundation
import SwiftData

/// Page-level bookmarks.
@MainActor
final class BookmarkStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func bookmarks(sourceId: String, mangaId: String) throws -> [BookmarkRecord] {
        try context.fetch(
            FetchDescriptor<BookmarkRecord>(
                predicate: #Predicate { $0.sourceId == sourceId && $0.mangaId == mangaId },
                sortBy: [SortDescriptor(\BookmarkRecord.createdAt, order: .reverse)]
            )
        )
    }

    func all() throws -> [BookmarkRecord] {
        try context.fetch(
            FetchDescriptor<BookmarkRecord>(sortBy: [SortDescriptor(\BookmarkRecord.createdAt, order: .reverse)])
        )
    }

    func contains(sourceId: String, mangaId: String, chapterId: String, pageIndex: Int) throws -> Bool {
        let key = "\(sourceId):\(mangaId):\(chapterId):\(pageIndex)"
        var descriptor = FetchDescriptor<BookmarkRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first != nil
    }

    /// Adds the bookmark if missing, removes it if present. Returns the new state.
    @discardableResult
    func toggle(
        sourceId: String,
        mangaId: String,
        mangaTitle: String,
        chapterId: String,
        chapterTitle: String?,
        pageIndex: Int,
        note: String? = nil
    ) throws -> Bool {
        let key = "\(sourceId):\(mangaId):\(chapterId):\(pageIndex)"
        var descriptor = FetchDescriptor<BookmarkRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1

        if let existing = try context.fetch(descriptor).first {
            context.delete(existing)
            if context.hasChanges { try context.save() }
            return false
        }

        context.insert(BookmarkRecord(
            sourceId: sourceId,
            mangaId: mangaId,
            mangaTitle: mangaTitle,
            chapterId: chapterId,
            chapterTitle: chapterTitle,
            pageIndex: pageIndex,
            note: note
        ))
        if context.hasChanges { try context.save() }
        return true
    }

    func containsKey(_ key: String) throws -> Bool {
        var descriptor = FetchDescriptor<BookmarkRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first != nil
    }

    func remove(_ bookmark: BookmarkRecord) throws {
        context.delete(bookmark)
        if context.hasChanges { try context.save() }
    }
}
