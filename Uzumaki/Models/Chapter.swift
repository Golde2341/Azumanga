import Foundation

/// A single readable chapter. `isRead` and `isBookmarked` are transient UI flags
/// populated from local persistence, not from the source.
nonisolated struct Chapter: Identifiable, Hashable, Sendable, Codable {
    let sourceId: String
    let mangaId: String
    let chapterId: String
    var title: String?
    var number: Double?
    var volume: String?
    var language: String
    var scanlator: String?
    var publishedAt: Date?
    var pageCount: Int?
    /// Set when the chapter is hosted off-site and cannot be served as pages.
    var externalURL: URL?
    var isRead: Bool = false
    var isBookmarked: Bool = false

    var id: String { "\(sourceId):\(chapterId)" }

    /// Human-friendly label, falling back to the chapter number when untitled.
    var displayName: String {
        if let title, !title.isEmpty { return title }
        if let number { return "Chapter \(Self.format(number))" }
        return "Oneshot"
    }

    var displayNumber: String {
        guard let number else { return "" }
        return Self.format(number)
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%g", value)
    }

    init(
        sourceId: String,
        mangaId: String,
        chapterId: String,
        title: String? = nil,
        number: Double? = nil,
        volume: String? = nil,
        language: String = "en",
        scanlator: String? = nil,
        publishedAt: Date? = nil,
        pageCount: Int? = nil,
        externalURL: URL? = nil,
        isRead: Bool = false,
        isBookmarked: Bool = false
    ) {
        self.sourceId = sourceId
        self.mangaId = mangaId
        self.chapterId = chapterId
        self.title = title
        self.number = number
        self.volume = volume
        self.language = language
        self.scanlator = scanlator
        self.publishedAt = publishedAt
        self.pageCount = pageCount
        self.externalURL = externalURL
        self.isRead = isRead
        self.isBookmarked = isBookmarked
    }

    /// Oldest first, with unnumbered entries last. This is the order used by the
    /// detail screen and by the reader's next/previous chapter navigation.
    static func readingOrder(_ chapters: [Chapter]) -> [Chapter] {
        chapters.sorted { lhs, rhs in
            switch (lhs.number, rhs.number) {
            case let (l?, r?): l < r
            case (nil, nil): false
            case (nil, _): false
            case (_, nil): true
            }
        }
    }
}
