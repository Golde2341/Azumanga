import Foundation
import SwiftData

/// A manga saved to the user's library. Caches the metadata needed to render the
/// library without hitting the network.
@Model
final class LibraryEntry {
    /// Stable identity: `"<sourceId>:<mangaId>"`.
    var key: String
    var sourceId: String
    var mangaId: String

    var title: String
    var coverURLString: String?
    var author: String?
    var artist: String?
    var statusRaw: String
    var contentRatingRaw: String
    var genres: [String]

    var dateAdded: Date
    var lastOpenedAt: Date?
    var isFavorite: Bool

    /// Where to resume reading.
    var lastReadChapterId: String?
    var lastReadChapterNumber: Double?
    var lastReadChapterTitle: String?
    var lastReadAt: Date?

    var categories: [MangaCategory]

    init(
        sourceId: String,
        mangaId: String,
        title: String,
        coverURLString: String? = nil,
        author: String? = nil,
        artist: String? = nil,
        status: PublicationStatus = .unknown,
        contentRating: ContentRating = .safe,
        genres: [String] = [],
        dateAdded: Date = Date(),
        isFavorite: Bool = false,
        categories: [MangaCategory] = []
    ) {
        self.key = "\(sourceId):\(mangaId)"
        self.sourceId = sourceId
        self.mangaId = mangaId
        self.title = title
        self.coverURLString = coverURLString
        self.author = author
        self.artist = artist
        self.statusRaw = status.rawValue
        self.contentRatingRaw = contentRating.rawValue
        self.genres = genres
        self.dateAdded = dateAdded
        self.lastOpenedAt = nil
        self.isFavorite = isFavorite
        self.categories = categories
    }

    var status: PublicationStatus {
        get { PublicationStatus(rawValue: statusRaw) ?? .unknown }
        set { statusRaw = newValue.rawValue }
    }

    var contentRating: ContentRating {
        get { ContentRating(rawValue: contentRatingRaw) ?? .safe }
        set { contentRatingRaw = newValue.rawValue }
    }

    var coverURL: URL? { coverURLString.flatMap(URL.init(string:)) }

    /// Rebuilds the domain value so views can share one representation.
    var manga: Manga {
        Manga(
            sourceId: sourceId,
            mangaId: mangaId,
            title: title,
            description: nil,
            coverURL: coverURL,
            author: author,
            artist: artist,
            status: status,
            genres: genres,
            contentRating: contentRating
        )
    }

    func refresh(with manga: Manga) {
        title = manga.title
        coverURLString = manga.coverURL?.absoluteString
        author = manga.author
        artist = manga.artist
        status = manga.status
        contentRating = manga.contentRating
        genres = manga.genres
    }
}

/// A user-defined grouping of library entries.
@Model
final class MangaCategory {
    var name: String
    var order: Int
    var createdAt: Date
    @Relationship(deleteRule: .nullify, inverse: \LibraryEntry.categories)
    var entries: [LibraryEntry]

    init(name: String, order: Int = 0, createdAt: Date = Date()) {
        self.name = name
        self.order = order
        self.createdAt = createdAt
        self.entries = []
    }
}
