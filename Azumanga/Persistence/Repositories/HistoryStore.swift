import Foundation
import SwiftData

/// Recently-opened manga, one row per manga.
@MainActor
final class HistoryStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func recent(limit: Int = 50) throws -> [HistoryRecord] {
        var descriptor = FetchDescriptor<HistoryRecord>(
            sortBy: [SortDescriptor(\HistoryRecord.visitedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    func record(manga: Manga, chapter: Chapter?, at date: Date = Date()) throws {
        let key = "\(manga.sourceId):\(manga.mangaId)"
        var descriptor = FetchDescriptor<HistoryRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1

        let record = try context.fetch(descriptor).first
            ?? {
                let new = HistoryRecord(
                    sourceId: manga.sourceId,
                    mangaId: manga.mangaId,
                    title: manga.title,
                    coverURLString: manga.coverURL?.absoluteString
                )
                context.insert(new)
                return new
            }()

        record.title = manga.title
        record.coverURLString = manga.coverURL?.absoluteString
        if let chapter {
            record.chapterId = chapter.chapterId
            record.chapterTitle = chapter.displayName
        }
        record.visitedAt = date

        if context.hasChanges {
            try context.save()
        }
    }

    func remove(_ record: HistoryRecord) throws {
        context.delete(record)
        if context.hasChanges { try context.save() }
    }

    func clear() throws {
        for record in try recent(limit: .max) {
            context.delete(record)
        }
        if context.hasChanges { try context.save() }
    }
}
