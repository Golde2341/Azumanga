import Foundation

/// Provider-agnostic description of a manga. `id` is a stable composite of the
/// owning source and the source-local manga id so items from different sources
/// never collide in SwiftUI collections.
nonisolated struct Manga: Identifiable, Hashable, Sendable, Codable {
    let sourceId: String
    let mangaId: String
    var title: String
    var altTitles: [String] = []
    var description: String?
    var coverURL: URL?
    var author: String?
    var artist: String?
    var status: PublicationStatus = .unknown
    var genres: [String] = []
    var contentRating: ContentRating = .safe
    var year: Int?
    var lastChapter: String?
    var webURL: URL?

    var id: String { "\(sourceId):\(mangaId)" }

    init(
        sourceId: String,
        mangaId: String,
        title: String,
        altTitles: [String] = [],
        description: String? = nil,
        coverURL: URL? = nil,
        author: String? = nil,
        artist: String? = nil,
        status: PublicationStatus = .unknown,
        genres: [String] = [],
        contentRating: ContentRating = .safe,
        year: Int? = nil,
        lastChapter: String? = nil,
        webURL: URL? = nil
    ) {
        self.sourceId = sourceId
        self.mangaId = mangaId
        self.title = title
        self.altTitles = altTitles
        self.description = description
        self.coverURL = coverURL
        self.author = author
        self.artist = artist
        self.status = status
        self.genres = genres
        self.contentRating = contentRating
        self.year = year
        self.lastChapter = lastChapter
        self.webURL = webURL
    }
}
