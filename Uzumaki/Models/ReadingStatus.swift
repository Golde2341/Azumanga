import Foundation

/// Progress of a chapter through the reader.
nonisolated enum ReadingStatus: String, Codable, Sendable, CaseIterable {
    case unread
    case reading
    case completed
}
