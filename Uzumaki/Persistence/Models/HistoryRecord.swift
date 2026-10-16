import Foundation
import SwiftData

/// Recently opened manga, newest first. One row per manga.
@Model
final class HistoryRecord {
    /// Stable identity: `"<sourceId>:<mangaId>"`.
    var key: String
    var sourceId: String
    var mangaId: String
    var title: String
    var coverURLString: String?
    var chapterId: String?
    var chapterTitle: String?
    var visitedAt: Date

    init(
        sourceId: String,
        mangaId: String,
        title: String,
        coverURLString: String? = nil,
        chapterId: String? = nil,
        chapterTitle: String? = nil,
        visitedAt: Date = Date()
    ) {
        self.key = "\(sourceId):\(mangaId)"
        self.sourceId = sourceId
        self.mangaId = mangaId
        self.title = title
        self.coverURLString = coverURLString
        self.chapterId = chapterId
        self.chapterTitle = chapterTitle
        self.visitedAt = visitedAt
    }

    var coverURL: URL? { coverURLString.flatMap(URL.init(string:)) }
}
