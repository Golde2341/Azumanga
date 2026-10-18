import Foundation

nonisolated enum MangaDexQuality: String, Codable, Sendable, CaseIterable, Identifiable {
    case dataSaver
    case data

    var id: String { rawValue }

    /// Path segment used when constructing image URLs from the at-home server.
    var pathComponent: String {
        self == .data ? "data" : "data-saver"
    }

    var displayName: String {
        self == .data ? "Original quality" : "Data saver (smaller)"
    }
}

nonisolated struct MangaDexConfiguration: Sendable, Equatable {
    var language: String = "en"
    var quality: MangaDexQuality = .dataSaver
    var contentRatings: Set<ContentRating> = ContentRating.safeDefaults
    var pageSize: Int = 30

    static let `default` = MangaDexConfiguration()
}

/// Builds MangaDex API requests. Pure and value-typed so it is trivially
/// testable and free of UI concerns.
nonisolated struct MangaDexAPI: Sendable {
    var apiBase = URL(string: "https://api.mangadex.org")!
    var uploadsBase = URL(string: "https://uploads.mangadex.org")!

    static let mangaListPageSize = 30
    static let mangaListMaxPageSize = 100
    static let chapterFeedPageSize = 500

    // MARK: - Manga lists

    func popularRequest(page: Int, configuration: MangaDexConfiguration) -> URLRequest {
        var items = listQueryItems(configuration: configuration)
        items.append(URLQueryItem(name: "order[followedCount]", value: "desc"))
        return makeRequest(path: "/manga", queryItems: items, page: page, pageSize: configuration.pageSize)
    }

    func latestRequest(page: Int, configuration: MangaDexConfiguration) -> URLRequest {
        var items = listQueryItems(configuration: configuration)
        items.append(URLQueryItem(name: "order[latestUploadedChapter]", value: "desc"))
        return makeRequest(path: "/manga", queryItems: items, page: page, pageSize: configuration.pageSize)
    }

    func searchRequest(
        query: String,
        page: Int,
        filters: [MangaFilterValue],
        configuration: MangaDexConfiguration
    ) -> URLRequest {
        var items = listQueryItems(configuration: configuration)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "title", value: trimmed))
            items.append(URLQueryItem(name: "order[relevance]", value: "desc"))
        } else {
            items.append(URLQueryItem(name: "order[followedCount]", value: "desc"))
        }
        items.append(contentsOf: Self.queryItems(for: filters))
        return makeRequest(path: "/manga", queryItems: items, page: page, pageSize: configuration.pageSize)
    }

    func detailsRequest(mangaId: String) -> URLRequest {
        makeRequest(path: "/manga/\(mangaId)", queryItems: Self.relationshipIncludes)
    }

    func chaptersRequest(
        mangaId: String,
        offset: Int,
        limit: Int,
        configuration: MangaDexConfiguration
    ) -> URLRequest {
        // Note: `includeExternalUrl` is deliberately omitted. It accepts only
        // "0"/"1" and, contrary to its name, "1" filters chapters down to none
        // for many manga. Omitting it returns hosted *and* externally-hosted
        // chapters, which is what we want (external ones are modelled on the
        // chapter so the UI can offer to open them).
        var items: [URLQueryItem] = [
            URLQueryItem(name: "translatedLanguage[]", value: configuration.language),
            URLQueryItem(name: "order[volume]", value: "asc"),
            URLQueryItem(name: "order[chapter]", value: "asc"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "includes[]", value: "scanlation_group"),
        ]
        items.append(contentsOf: configuration.contentRatings.sorted { $0.rawValue < $1.rawValue }.map {
            URLQueryItem(name: "contentRating[]", value: $0.rawValue)
        })
        return makeRequest(path: "/manga/\(mangaId)/feed", queryItems: items)
    }

    func atHomeRequest(chapterId: String) -> URLRequest {
        makeRequest(path: "/at-home/server/\(chapterId)", queryItems: [])
    }

    func tagsRequest() -> URLRequest {
        makeRequest(path: "/manga/tag", queryItems: [])
    }

    // MARK: - Filters

    /// Descriptors for the browse/search filter bar.
    static func filterDescriptors() -> [MangaFilter] {
        [
            MangaFilter(id: "status", name: "Status", kind: .select(options: [
                .init(id: "", name: "Any"),
                .init(id: "ongoing", name: "Ongoing"),
                .init(id: "completed", name: "Completed"),
                .init(id: "hiatus", name: "Hiatus"),
                .init(id: "cancelled", name: "Cancelled"),
            ])),
            MangaFilter(id: "demographic", name: "Demographic", kind: .select(options: [
                .init(id: "", name: "Any"),
                .init(id: "shounen", name: "Shounen"),
                .init(id: "shoujo", name: "Shoujo"),
                .init(id: "seinen", name: "Seinen"),
                .init(id: "josei", name: "Josei"),
                .init(id: "none", name: "None"),
            ])),
            MangaFilter(id: "contentRating", name: "Content", kind: .multiSelect(options: [
                .init(id: "safe", name: "Safe"),
                .init(id: "suggestive", name: "Suggestive"),
                .init(id: "erotica", name: "Erotica"),
                .init(id: "pornographic", name: "Pornographic"),
            ])),
            MangaFilter(id: "originalLanguage", name: "Original language", kind: .multiSelect(options: [
                .init(id: "ja", name: "Japanese"),
                .init(id: "ko", name: "Korean"),
                .init(id: "zh", name: "Chinese"),
                .init(id: "zh-hk", name: "Chinese (Hong Kong)"),
                .init(id: "en", name: "English"),
            ])),
            MangaFilter(id: "year", name: "Year", kind: .text),
        ]
    }

    static func queryItems(for filters: [MangaFilterValue]) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        for filter in filters {
            switch filter.kind {
            case .text(let value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    items.append(URLQueryItem(name: filter.filterId, value: trimmed))
                }
            case .toggle(let value):
                items.append(URLQueryItem(name: filter.filterId, value: String(value)))
            case .select(let value):
                if !value.isEmpty {
                    items.append(URLQueryItem(name: "\(filter.filterId)[]", value: value))
                }
            case .multiSelect(let values):
                for value in values where !value.isEmpty {
                    items.append(URLQueryItem(name: "\(filter.filterId)[]", value: value))
                }
            }
        }
        return items
    }

    // MARK: - Building blocks

    var coverBase: URL { uploadsBase.appendingPathComponent("covers") }

    private func listQueryItems(configuration: MangaDexConfiguration) -> [URLQueryItem] {
        var items = Self.relationshipIncludes
        items.append(URLQueryItem(name: "hasAvailableChapters", value: "true"))
        items.append(contentsOf: configuration.contentRatings.sorted { $0.rawValue < $1.rawValue }.map {
            URLQueryItem(name: "contentRating[]", value: $0.rawValue)
        })
        return items
    }

    private static let relationshipIncludes: [URLQueryItem] = [
        URLQueryItem(name: "includes[]", value: "cover_art"),
        URLQueryItem(name: "includes[]", value: "author"),
        URLQueryItem(name: "includes[]", value: "artist"),
    ]

    private func makeRequest(
        path: String,
        queryItems: [URLQueryItem],
        page: Int? = nil,
        pageSize: Int? = nil
    ) -> URLRequest {
        var items = queryItems
        if let page, let pageSize {
            items.append(URLQueryItem(name: "limit", value: String(min(pageSize, Self.mangaListMaxPageSize))))
            items.append(URLQueryItem(name: "offset", value: String(max(0, page) * pageSize)))
        }
        var components = URLComponents(url: apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = items.isEmpty ? nil : items
        let url = components?.url ?? apiBase.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return request
    }
}
