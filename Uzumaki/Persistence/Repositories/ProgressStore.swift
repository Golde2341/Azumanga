import Foundation
import SwiftData

/// Owns reading progress: where the user left off in each chapter and which
/// chapters are finished.
@MainActor
final class ProgressStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func record(sourceId: String, mangaId: String, chapterId: String) throws -> ReadingProgressRecord? {
        let key = "\(sourceId):\(mangaId):\(chapterId)"
        var descriptor = FetchDescriptor<ReadingProgressRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Creates or updates a progress row. Completing the chapter marks it read.
    @discardableResult
    func update(
        sourceId: String,
        mangaId: String,
        chapterId: String,
        chapterNumber: Double?,
        chapterTitle: String?,
        pageIndex: Int,
        totalPages: Int,
        at date: Date = Date()
    ) throws -> ReadingProgressRecord {
        let record = try record(sourceId: sourceId, mangaId: mangaId, chapterId: chapterId)
            ?? {
                let new = ReadingProgressRecord(
                    sourceId: sourceId,
                    mangaId: mangaId,
                    chapterId: chapterId,
                    chapterNumber: chapterNumber,
                    chapterTitle: chapterTitle
                )
                context.insert(new)
                return new
            }()

        record.chapterNumber = chapterNumber ?? record.chapterNumber
        record.chapterTitle = chapterTitle ?? record.chapterTitle
        record.lastPageIndex = max(0, pageIndex)
        record.totalPages = max(record.totalPages, totalPages)
        record.updatedAt = date

        // Consider a chapter finished once the final page is shown.
        if totalPages > 0, pageIndex >= totalPages - 1 {
            record.status = .completed
        } else if record.status != .completed {
            record.status = .reading
        }

        try save()
        return record
    }

    func setStatus(_ status: ReadingStatus, sourceId: String, mangaId: String, chapterId: String, chapterNumber: Double? = nil, chapterTitle: String? = nil) throws {
        let record = try record(sourceId: sourceId, mangaId: mangaId, chapterId: chapterId)
            ?? {
                let new = ReadingProgressRecord(
                    sourceId: sourceId,
                    mangaId: mangaId,
                    chapterId: chapterId,
                    chapterNumber: chapterNumber,
                    chapterTitle: chapterTitle
                )
                context.insert(new)
                return new
            }()
        record.status = status
        if status == .unread {
            record.lastPageIndex = 0
        }
        record.updatedAt = Date()
        try save()
    }

    func markRead(_ chapter: Chapter) throws {
        try setStatus(.completed, sourceId: chapter.sourceId, mangaId: chapter.mangaId, chapterId: chapter.chapterId, chapterNumber: chapter.number, chapterTitle: chapter.title)
    }

    func markUnread(_ chapter: Chapter) throws {
        try setStatus(.unread, sourceId: chapter.sourceId, mangaId: chapter.mangaId, chapterId: chapter.chapterId)
    }

    /// Chapter ids that have been fully read, for a single manga.
    func readChapterIds(sourceId: String, mangaId: String) throws -> Set<String> {
        let descriptor = FetchDescriptor<ReadingProgressRecord>(
            predicate: #Predicate { $0.sourceId == sourceId && $0.mangaId == mangaId && $0.statusRaw == "completed" }
        )
        return Set(try context.fetch(descriptor).map(\.chapterId))
    }

    func allRecords(sourceId: String, mangaId: String) throws -> [ReadingProgressRecord] {
        try context.fetch(
            FetchDescriptor<ReadingProgressRecord>(
                predicate: #Predicate { $0.sourceId == sourceId && $0.mangaId == mangaId }
            )
        )
    }

    /// Most recently read chapters across the whole library, newest first.
    func recentlyRead(limit: Int = 20) throws -> [ReadingProgressRecord] {
        var descriptor = FetchDescriptor<ReadingProgressRecord>(
            predicate: #Predicate { $0.statusRaw != "unread" },
            sortBy: [SortDescriptor(\ReadingProgressRecord.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    func deleteAll(sourceId: String, mangaId: String) throws {
        for record in try allRecords(sourceId: sourceId, mangaId: mangaId) {
            context.delete(record)
        }
        try save()
    }

    func delete(_ record: ReadingProgressRecord) throws {
        context.delete(record)
        try save()
    }

    func save() throws {
        if context.hasChanges {
            try context.save()
        }
    }
}
