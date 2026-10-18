import Foundation

/// Translates MangaDex DTOs into provider-agnostic domain models. All mapping
/// is pure so it can be unit-tested against captured API payloads.
nonisolated enum MangaDexMapper {
    static let sourceId = "org.mangadex"

    // MARK: - Manga

    static func manga(from entity: MDEntity<MDMangaAttributes>, api: MangaDexAPI = MangaDexAPI()) throws -> Manga {
        guard let attributes = entity.attributes else {
            throw MangaSourceError.decoding("Manga entry \(entity.id) had no attributes")
        }
        let relationships = entity.relationships ?? []

        let authors = relationships
            .filter { $0.type == "author" }
            .compactMap { $0.attributes?.name }
        let artists = relationships
            .filter { $0.type == "artist" }
            .compactMap { $0.attributes?.name }

        return Manga(
            sourceId: sourceId,
            mangaId: entity.id,
            title: displayTitle(from: attributes),
            altTitles: (attributes.altTitles ?? []).compactMap(\.preferred).filter { !$0.isEmpty },
            description: attributes.description?.preferred?.nilIfBlank,
            coverURL: coverURL(mangaId: entity.id, relationships: relationships, api: api),
            author: authors.isEmpty ? nil : authors.joined(separator: ", "),
            artist: artists.isEmpty ? nil : artists.joined(separator: ", "),
            status: publicationStatus(from: attributes.status),
            genres: genres(from: attributes.tags ?? []),
            contentRating: contentRating(from: attributes.contentRating),
            year: attributes.year,
            lastChapter: attributes.lastChapter?.nilIfBlank,
            webURL: URL(string: "https://mangadex.org/title/\(entity.id)")
        )
    }

    static func coverURL(
        mangaId: String,
        relationships: [MDRelationship],
        api: MangaDexAPI = MangaDexAPI()
    ) -> URL? {
        guard let fileName = relationships.first(where: { $0.type == "cover_art" })?.attributes?.fileName else {
            return nil
        }
        return api.coverBase
            .appendingPathComponent(mangaId)
            .appendingPathComponent("\(fileName).512.jpg")
    }

    /// MangaDex's `title` is the primary title and is often non-English, while
    /// an English translation usually lives in `altTitles`. Prefer English.
    static func displayTitle(from attributes: MDMangaAttributes) -> String {
        if let english = attributes.title.values["en"], !english.isEmpty {
            return english
        }
        for altTitle in attributes.altTitles ?? [] {
            if let english = altTitle.values["en"], !english.isEmpty {
                return english
            }
        }
        return attributes.title.preferred ?? "Untitled"
    }

    static func publicationStatus(from raw: String?) -> PublicationStatus {
        switch raw {
        case "ongoing": .ongoing
        case "completed": .completed
        case "hiatus": .hiatus
        case "cancelled": .cancelled
        default: .unknown
        }
    }

    static func contentRating(from raw: String?) -> ContentRating {
        ContentRating(rawValue: raw ?? "") ?? .safe
    }

    static func genres(from tags: [MDTag]) -> [String] {
        tags
            .filter { $0.attributes?.group == "genre" || $0.attributes?.group == "theme" }
            .compactMap { $0.attributes?.name.preferred }
            .filter { !$0.isEmpty }
    }

    // MARK: - Chapters

    static func chapter(from entity: MDEntity<MDChapterAttributes>, mangaId: String) -> Chapter {
        let attributes = entity.attributes
        let scanlator = entity.relationships?
            .first { $0.type == "scanlation_group" }?
            .attributes?.name

        return Chapter(
            sourceId: sourceId,
            mangaId: mangaId,
            chapterId: entity.id,
            title: attributes?.title?.nilIfBlank,
            number: chapterNumber(from: attributes?.chapter),
            volume: attributes?.volume?.nilIfBlank,
            language: attributes?.translatedLanguage ?? "en",
            scanlator: scanlator?.nilIfBlank,
            publishedAt: attributes?.readableAt ?? attributes?.publishAt ?? attributes?.createdAt,
            pageCount: attributes?.pages,
            externalURL: attributes?.externalUrl.flatMap { URL(string: $0) }
        )
    }

    /// MangaDex encodes the chapter number as a string and occasionally leaves it
    /// blank (oneshots) or non-numeric.
    static func chapterNumber(from raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return Double(raw)
    }

    // MARK: - Pages

    static func pages(from atHome: MDAtHome, quality: MangaDexQuality) -> [Page] {
        let filenames = quality == .data ? atHome.chapter.data : atHome.chapter.dataSaver
        // `baseUrl` is an opaque string per the MangaDex docs — never assume a
        // shape, just trim any trailing slash and join the path segments.
        var base = atHome.baseUrl
        while base.hasSuffix("/") { base.removeLast() }
        guard let directory = URL(string: "\(base)/\(quality.pathComponent)/\(atHome.chapter.hash)/") else {
            return []
        }

        // MangaDex asks that delivery of images from third-party MangaDex@Home
        // nodes be reported back so unhealthy mirrors can be retired.
        let reportURL: URL? = base.contains("mangadex.org")
            ? nil
            : URL(string: "https://api.mangadex.network/report")

        return filenames.enumerated().compactMap { index, filename in
            guard !filename.isEmpty else { return nil }
            return Page(index: index, url: directory.appendingPathComponent(filename), healthReportURL: reportURL)
        }
    }
}

nonisolated extension String {
    /// `nil` when the string is empty or only whitespace.
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
