import Foundation

// MARK: - Wire types
//
// Mirrors of the parser host's JSON (see ParserHost/README.md). The `Manga` and
// `Chapter` payloads are `Codable` in both directions on purpose: the parsers need
// the object back to fetch details and pages, so what we decode is what we send.

nonisolated struct KotatsuMangaDTO: Codable, Sendable, Equatable {
    var id: Int64
    var title: String
    var altTitles: [String]?
    var url: String
    var publicUrl: String?
    var rating: Double?
    var coverUrl: String?
    var largeCoverUrl: String?
    var description: String?
    var state: String?
    var contentRating: String?
    var sourceKey: String?
    var authors: [String]?
    var tags: [Tag]?
    var chapters: [KotatsuChapterDTO]?

    nonisolated struct Tag: Codable, Sendable, Equatable {
        var title: String
        var key: String
    }
}

nonisolated struct KotatsuChapterDTO: Codable, Sendable, Equatable {
    var id: Int64
    var title: String?
    var number: Double?
    var volume: Int?
    var url: String?
    var scanlator: String?
    var uploadDate: Int64?
    var branch: String?
}

nonisolated struct KotatsuMangaListDTO: Decodable, Sendable {
    var items: [KotatsuMangaDTO]
}

nonisolated struct KotatsuPageDTO: Decodable, Sendable {
    var id: Int64
    var url: String
    var resolvedUrl: String?
    var preview: String?
}

nonisolated struct KotatsuPageListDTO: Decodable, Sendable {
    var items: [KotatsuPageDTO]
}

nonisolated struct KotatsuSourceDTO: Decodable, Sendable, Equatable {
    var key: String
    var title: String
    var locale: String
    var contentType: String
    var broken: Bool
}

nonisolated struct KotatsuSourceListDTO: Decodable, Sendable {
    var items: [KotatsuSourceDTO]
}

/// One batch health-check request. The host checks these sources concurrently.
nonisolated struct KotatsuHealthRequest: Encodable, Sendable {
    var sources: [String]
    var timeoutMs: Int
}

nonisolated struct KotatsuHealthResponse: Decodable, Sendable {
    var items: [Item]

    nonisolated struct Item: Decodable, Sendable {
        var key: String
        var ok: Bool
        var detail: String?
        var count: Int?
    }
}

nonisolated struct KotatsuFilterOptionsDTO: Decodable, Sendable {
    var sortOrders: [String]
    var capabilities: Capabilities
    var options: Options

    nonisolated struct Capabilities: Decodable, Sendable {
        var search: Bool
        var searchWithFilters: Bool
        var multipleTags: Bool
        var tagsExclusion: Bool
        var year: Bool
        var yearRange: Bool
        var author: Bool
    }

    nonisolated struct Options: Decodable, Sendable {
        var tags: [KotatsuMangaDTO.Tag]?
        var states: [String]?
        var contentRatings: [String]?
        var contentTypes: [String]?
        var demographics: [String]?
    }
}

// MARK: - Request payloads

nonisolated struct KotatsuListParameters: Encodable, Sendable {
    var key: String
    var offset: Int
    var sort: String?
    var query: String?
    var states: [String]?
    var contentRatings: [String]?
    var types: [String]?
    var demographics: [String]?
    var yearFrom: Int?
    var yearTo: Int?
    var author: String?
}

nonisolated struct KotatsuDetailsParameters: Encodable, Sendable {
    var key: String
    var manga: KotatsuMangaDTO
}

nonisolated struct KotatsuPagesParameters: Encodable, Sendable {
    var key: String
    var chapter: KotatsuChapterDTO
}

// MARK: - Mapping

/// Translates Kotatsu wire types into provider-agnostic domain models.
///
/// Images are wrapped in `HostImageURL` rather than passed through: these CDNs
/// reject requests that don't come from the parser's own client.
nonisolated enum KotatsuMapper {
    static func manga(_ dto: KotatsuMangaDTO, sourceId: String, sourceKey: String) -> Manga {
        let authors = (dto.authors ?? []).filter { !$0.isEmpty }
        return Manga(
            sourceId: sourceId,
            mangaId: String(dto.id),
            title: dto.title,
            altTitles: dto.altTitles ?? [],
            description: dto.description?.nilIfBlank,
            coverURL: coverURL(dto, sourceKey: sourceKey),
            author: authors.isEmpty ? nil : authors.joined(separator: ", "),
            artist: nil,
            status: publicationStatus(from: dto.state),
            genres: (dto.tags ?? []).map(\.title),
            contentRating: contentRating(from: dto.contentRating),
            year: nil,
            lastChapter: nil,
            webURL: dto.publicUrl.flatMap(URL.init(string:))
        )
    }

    static func coverURL(_ dto: KotatsuMangaDTO, sourceKey: String) -> URL? {
        let candidate = dto.largeCoverUrl?.nilIfBlank ?? dto.coverUrl?.nilIfBlank
        guard let candidate, let remote = URL(string: candidate) else { return nil }
        return HostImageURL.make(sourceKey: sourceKey, remote: remote) ?? remote
    }

    static func chapter(
        _ dto: KotatsuChapterDTO,
        sourceId: String,
        mangaId: String,
        language: String
    ) -> Chapter {
        Chapter(
            sourceId: sourceId,
            mangaId: mangaId,
            chapterId: String(dto.id),
            title: dto.title?.nilIfBlank,
            number: dto.number,
            volume: (dto.volume ?? 0) > 0 ? String(dto.volume ?? 0) : nil,
            language: language,
            scanlator: dto.scanlator?.nilIfBlank,
            publishedAt: dto.uploadDate.map { Date(timeIntervalSince1970: Double($0) / 1000) },
            pageCount: nil,
            externalURL: nil
        )
    }

    static func pages(_ dtos: [KotatsuPageDTO], sourceKey: String) -> [Page] {
        dtos.enumerated().compactMap { index, dto in
            let candidate = dto.resolvedUrl?.nilIfBlank ?? dto.url.nilIfBlank
            guard let candidate, let remote = URL(string: candidate) else { return nil }
            let url = HostImageURL.make(sourceKey: sourceKey, remote: remote) ?? remote
            return Page(index: index, url: url)
        }
    }

    static func publicationStatus(from raw: String?) -> PublicationStatus {
        switch raw?.uppercased() {
        case "ONGOING": .ongoing
        case "FINISHED": .completed
        case "ABANDONED": .cancelled
        case "PAUSED": .hiatus
        default: .unknown
        }
    }

    static func contentRating(from raw: String?) -> ContentRating {
        switch raw?.uppercased() {
        case "SUGGESTIVE": .suggestive
        case "ADULT": .erotica
        default: .safe
        }
    }

    /// Filter descriptors the UI can render, using the host's own parameter names
    /// as ids so values pass straight through to `list`.
    static func filters(from options: KotatsuFilterOptionsDTO) -> [MangaFilter] {
        var filters: [MangaFilter] = []

        if !options.sortOrders.isEmpty {
            filters.append(MangaFilter(
                id: "sort",
                name: "Sort by",
                kind: .select(options: options.sortOrders.map { sortOrder in
                    MangaFilter.Option(id: sortOrder, name: humanize(sortOrder))
                })
            ))
        }

        if let states = options.options.states, !states.isEmpty {
            filters.append(multiSelect(id: "states", name: "Status", values: states))
        }
        if let ratings = options.options.contentRatings, !ratings.isEmpty {
            filters.append(multiSelect(id: "contentRatings", name: "Content", values: ratings))
        }
        if let types = options.options.contentTypes, !types.isEmpty {
            filters.append(multiSelect(id: "types", name: "Type", values: types))
        }
        if let demographics = options.options.demographics, !demographics.isEmpty {
            filters.append(multiSelect(id: "demographics", name: "Demographic", values: demographics))
        }
        if options.capabilities.year {
            filters.append(MangaFilter(id: "yearFrom", name: "Year from", kind: .text))
        }
        if options.capabilities.author {
            filters.append(MangaFilter(id: "author", name: "Author", kind: .text))
        }
        return filters
    }

    private static func multiSelect(id: String, name: String, values: [String]) -> MangaFilter {
        MangaFilter(
            id: id,
            name: name,
            kind: .multiSelect(options: values.map { MangaFilter.Option(id: $0, name: humanize($0)) })
        )
    }

    /// `POPULARITY_DESC` → `Popularity desc`; `SAFE` → `Safe`.
    static func humanize(_ value: String) -> String {
        let spaced = value.replacingOccurrences(of: "_", with: " ").lowercased()
        guard let first = spaced.first else { return value }
        return first.uppercased() + spaced.dropFirst()
    }
}
