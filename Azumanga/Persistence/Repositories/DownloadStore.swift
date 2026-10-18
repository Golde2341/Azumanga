import Foundation
import SwiftData

/// Persists offline download state.
@MainActor
final class DownloadStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func all() throws -> [DownloadRecord] {
        try context.fetch(
            FetchDescriptor<DownloadRecord>(sortBy: [SortDescriptor(\DownloadRecord.updatedAt, order: .reverse)])
        )
    }

    func record(sourceId: String, mangaId: String, chapterId: String) throws -> DownloadRecord? {
        let key = "\(sourceId):\(mangaId):\(chapterId)"
        var descriptor = FetchDescriptor<DownloadRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func records(sourceId: String, mangaId: String) throws -> [DownloadRecord] {
        try context.fetch(
            FetchDescriptor<DownloadRecord>(
                predicate: #Predicate { $0.sourceId == sourceId && $0.mangaId == mangaId },
                sortBy: [SortDescriptor(\DownloadRecord.chapterNumber, order: .forward)]
            )
        )
    }

    @discardableResult
    func upsert(_ record: DownloadRecord) throws -> DownloadRecord {
        if try self.record(sourceId: record.sourceId, mangaId: record.mangaId, chapterId: record.chapterId) == nil {
            context.insert(record)
        }
        if context.hasChanges { try context.save() }
        return record
    }

    func update(
        sourceId: String,
        mangaId: String,
        chapterId: String,
        state: DownloadState? = nil,
        downloadedPages: Int? = nil,
        totalPages: Int? = nil,
        byteCount: Int64? = nil,
        errorMessage: String?? = nil
    ) throws {
        guard let record = try record(sourceId: sourceId, mangaId: mangaId, chapterId: chapterId) else { return }
        if let state { record.state = state }
        if let downloadedPages { record.downloadedPages = downloadedPages }
        if let totalPages { record.totalPages = totalPages }
        if let byteCount { record.byteCount = byteCount }
        if let errorMessage { record.errorMessage = errorMessage }
        record.updatedAt = Date()
        if context.hasChanges { try context.save() }
    }

    func delete(_ record: DownloadRecord) throws {
        context.delete(record)
        if context.hasChanges { try context.save() }
    }

    func totalByteCount() throws -> Int64 {
        try all().reduce(into: Int64(0)) { $0 += $1.byteCount }
    }

    func completedCount() throws -> Int {
        try context.fetchCount(FetchDescriptor<DownloadRecord>(predicate: #Predicate { $0.stateRaw == "completed" }))
    }
}
