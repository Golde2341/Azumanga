import Foundation
import SwiftData

/// Per-chapter reading progress and completion state.
@Model
final class ReadingProgressRecord {
    /// Stable identity: `"<sourceId>:<mangaId>:<chapterId>"`.
    var key: String
    var sourceId: String
    var mangaId: String
    var chapterId: String
    var chapterNumber: Double?
    var chapterTitle: String?

    var lastPageIndex: Int
    var totalPages: Int
    var statusRaw: String
    var updatedAt: Date

    init(
        sourceId: String,
        mangaId: String,
        chapterId: String,
        chapterNumber: Double? = nil,
        chapterTitle: String? = nil,
        lastPageIndex: Int = 0,
        totalPages: Int = 0,
        status: ReadingStatus = .reading,
        updatedAt: Date = Date()
    ) {
        self.key = "\(sourceId):\(mangaId):\(chapterId)"
        self.sourceId = sourceId
        self.mangaId = mangaId
        self.chapterId = chapterId
        self.chapterNumber = chapterNumber
        self.chapterTitle = chapterTitle
        self.lastPageIndex = lastPageIndex
        self.totalPages = totalPages
        self.statusRaw = status.rawValue
        self.updatedAt = updatedAt
    }

    var status: ReadingStatus {
        get { ReadingStatus(rawValue: statusRaw) ?? .unread }
        set { statusRaw = newValue.rawValue }
    }

    var isRead: Bool { status == .completed }
}
