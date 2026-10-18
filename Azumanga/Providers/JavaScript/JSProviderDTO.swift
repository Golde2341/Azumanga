import Foundation

// MARK: - Wire types
//
// These mirror the JSON contract documented in Documentation/ProviderAPI.md.
// A provider's JavaScript returns plain objects; everything is decoded here so
// malformed output surfaces as a decoding error rather than a crash.

nonisolated struct JSProviderManga: Decodable, Sendable {
    var id: String
    var title: String
    var altTitles: [String]?
    var description: String?
    var coverURL: String?
    var author: String?
    var artist: String?
    var status: String?
    var genres: [String]?
    var contentRating: String?
    var year: Int?
    var lastChapter: String?
    var url: String?
}

nonisolated struct JSProviderMangaList: Decodable, Sendable {
    var items: [JSProviderManga]
    var hasNextPage: Bool?
    var total: Int?
}

nonisolated struct JSProviderChapter: Decodable, Sendable {
    var id: String
    var title: String?
    var number: Double?
    var volume: String?
    var language: String?
    var scanlator: String?
    /// Milliseconds since the Unix epoch.
    var publishedAt: Double?
    var pageCount: Int?
    var url: String?
}

nonisolated struct JSProviderChapterList: Decodable, Sendable {
    var items: [JSProviderChapter]
}

nonisolated struct JSProviderPage: Decodable, Sendable {
    var url: String
    var headers: [String: String]?
}

nonisolated struct JSProviderPageList: Decodable, Sendable {
    var items: [JSProviderPage]
}

nonisolated struct JSProviderFilter: Decodable, Sendable {
    var id: String
    var name: String
    var kind: String
    var options: [Option]?
    var filters: [JSProviderFilter]?

    nonisolated struct Option: Decodable, Sendable {
        var id: String
        var name: String
    }
}

nonisolated struct JSProviderFilterList: Decodable, Sendable {
    var items: [JSProviderFilter]
}

// MARK: - Mapping

/// Translates provider JSON into provider-agnostic domain models.
nonisolated enum JSProviderMapper {
    static func manga(_ dto: JSProviderManga, sourceId: String) -> Manga {
        Manga(
            sourceId: sourceId,
            mangaId: dto.id,
            title: dto.title,
            altTitles: dto.altTitles ?? [],
            description: dto.description?.nilIfBlank,
            coverURL: dto.coverURL.flatMap { URL(string: $0) },
            author: dto.author?.nilIfBlank,
            artist: dto.artist?.nilIfBlank,
            status: publicationStatus(from: dto.status),
            genres: dto.genres ?? [],
            contentRating: ContentRating(rawValue: dto.contentRating ?? "") ?? .safe,
            year: dto.year,
            lastChapter: dto.lastChapter?.nilIfBlank,
            webURL: dto.url.flatMap { URL(string: $0) }
        )
    }

    static func chapter(_ dto: JSProviderChapter, sourceId: String, mangaId: String) -> Chapter {
        Chapter(
            sourceId: sourceId,
            mangaId: mangaId,
            chapterId: dto.id,
            title: dto.title?.nilIfBlank,
            number: dto.number,
            volume: dto.volume?.nilIfBlank,
            language: dto.language ?? "en",
            scanlator: dto.scanlator?.nilIfBlank,
            publishedAt: dto.publishedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            pageCount: dto.pageCount,
            externalURL: dto.url.flatMap { URL(string: $0) }
        )
    }

    static func pages(_ dtos: [JSProviderPage]) -> [Page] {
        dtos.enumerated().compactMap { index, dto in
            URL(string: dto.url).map { Page(index: index, url: $0, headers: dto.headers ?? [:]) }
        }
    }

    static func filter(_ dto: JSProviderFilter) -> MangaFilter {
        let kind: MangaFilter.Kind
        switch dto.kind {
        case "text":
            kind = .text
        case "toggle":
            kind = .toggle
        case "select":
            kind = .select(options: options(dto))
        case "multiSelect":
            kind = .multiSelect(options: options(dto))
        case "group":
            kind = .group(filters: (dto.filters ?? []).map(filter))
        default:
            kind = .text
        }
        return MangaFilter(id: dto.id, name: dto.name, kind: kind)
    }

    private static func options(_ dto: JSProviderFilter) -> [MangaFilter.Option] {
        (dto.options ?? []).map { MangaFilter.Option(id: $0.id, name: $0.name) }
    }

    static func publicationStatus(from raw: String?) -> PublicationStatus {
        switch raw?.lowercased() {
        case "ongoing": .ongoing
        case "completed": .completed
        case "hiatus": .hiatus
        case "cancelled", "canceled": .cancelled
        default: .unknown
        }
    }

    /// Filter values are handed to JavaScript as plain objects keyed by filter id.
    static func filterArguments(_ filters: [MangaFilterValue]) -> [String: Any] {
        var result: [String: Any] = [:]
        for filter in filters {
            switch filter.kind {
            case .text(let value):
                result[filter.filterId] = value
            case .toggle(let value):
                result[filter.filterId] = value
            case .select(let value):
                result[filter.filterId] = value
            case .multiSelect(let values):
                result[filter.filterId] = values
            }
        }
        return result
    }
}
