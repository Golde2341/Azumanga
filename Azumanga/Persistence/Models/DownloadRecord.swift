import Foundation
import SwiftData

/// Lifecycle of an offline chapter download.
nonisolated enum DownloadState: String, Codable, Sendable, CaseIterable {
    case queued
    case downloading
    case paused
    case completed
    case failed
}

/// Persisted state of an offline chapter download.
@Model
final class DownloadRecord {
    /// Stable identity: `"<sourceId>:<mangaId>:<chapterId>"`.
    var key: String
    var sourceId: String
    var mangaId: String
    var chapterId: String
    var chapterTitle: String?
    var chapterNumber: Double?
    var mangaTitle: String

    var stateRaw: String
    var downloadedPages: Int
    var totalPages: Int
    var byteCount: Int64
    var directoryName: String
    var errorMessage: String?
    var updatedAt: Date

    init(
        sourceId: String,
        mangaId: String,
        mangaTitle: String,
        chapterId: String,
        chapterTitle: String? = nil,
        chapterNumber: Double? = nil,
        state: DownloadState = .queued,
        downloadedPages: Int = 0,
        totalPages: Int = 0,
        byteCount: Int64 = 0,
        directoryName: String,
        updatedAt: Date = Date()
    ) {
        self.key = "\(sourceId):\(mangaId):\(chapterId)"
        self.sourceId = sourceId
        self.mangaId = mangaId
        self.mangaTitle = mangaTitle
        self.chapterId = chapterId
        self.chapterTitle = chapterTitle
        self.chapterNumber = chapterNumber
        self.stateRaw = state.rawValue
        self.downloadedPages = downloadedPages
        self.totalPages = totalPages
        self.byteCount = byteCount
        self.directoryName = directoryName
        self.updatedAt = updatedAt
    }

    var state: DownloadState {
        get { DownloadState(rawValue: stateRaw) ?? .queued }
        set { stateRaw = newValue.rawValue }
    }

    var progress: Double {
        guard totalPages > 0 else { return state == .completed ? 1 : 0 }
        return min(1, Double(downloadedPages) / Double(totalPages))
    }
}
