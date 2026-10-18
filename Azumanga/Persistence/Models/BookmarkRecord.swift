import Foundation
import SwiftData

/// A bookmark at a specific page of a chapter. Titles are denormalised so the
/// bookmark list can describe itself without fetching from the source.
@Model
final class BookmarkRecord {
    /// Stable identity: `"<sourceId>:<mangaId>:<chapterId>:<pageIndex>"`.
    var key: String
    var sourceId: String
    var mangaId: String
    var mangaTitle: String
    var chapterId: String
    var chapterTitle: String?
    var pageIndex: Int
    var note: String?
    var createdAt: Date

    init(
        sourceId: String,
        mangaId: String,
        mangaTitle: String,
        chapterId: String,
        chapterTitle: String? = nil,
        pageIndex: Int,
        note: String? = nil,
        createdAt: Date = Date()
    ) {
        self.key = "\(sourceId):\(mangaId):\(chapterId):\(pageIndex)"
        self.sourceId = sourceId
        self.mangaId = mangaId
        self.mangaTitle = mangaTitle
        self.chapterId = chapterId
        self.chapterTitle = chapterTitle
        self.pageIndex = pageIndex
        self.note = note
        self.createdAt = createdAt
    }

    var manga: Manga {
        Manga(sourceId: sourceId, mangaId: mangaId, title: mangaTitle)
    }
}
