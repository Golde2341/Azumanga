import Foundation

/// Native MangaDex provider built directly on the documented `api.mangadex.org`
/// API. No scraping: every request goes through `MangaDexAPI` and is rate
/// limited by `HTTPClient`.
actor MangaDexSource: MangaSource {
    nonisolated let id = MangaDexMapper.sourceId
    nonisolated let name = "MangaDex"
    nonisolated let version = "1.0.0"
    nonisolated let isBuiltIn = true
    nonisolated let language: String
    nonisolated let capabilities: Set<SourceCapability> = [
        .search, .popular, .latest, .filters, .chapters, .pages,
    ]

    private let api: MangaDexAPI
    private let client: HTTPClient
    private let configuration: MangaDexConfiguration

    init(
        configuration: MangaDexConfiguration = .default,
        api: MangaDexAPI = MangaDexAPI(),
        client: HTTPClient = HTTPClient()
    ) {
        self.configuration = configuration
        self.api = api
        self.client = client
        self.language = configuration.language
    }

    func popular(page: Int) async throws -> PagedResult<Manga> {
        try await mangaList(api.popularRequest(page: page, configuration: configuration))
    }

    func latest(page: Int) async throws -> PagedResult<Manga> {
        try await mangaList(api.latestRequest(page: page, configuration: configuration))
    }

    func search(_ query: String, page: Int, filters: [MangaFilterValue]) async throws -> PagedResult<Manga> {
        try await mangaList(api.searchRequest(query: query, page: page, filters: filters, configuration: configuration))
    }

    func mangaDetails(id: String) async throws -> Manga {
        let envelope: MDEnvelope<MDEntity<MDMangaAttributes>> = try await perform(api.detailsRequest(mangaId: id))
        return try MangaDexMapper.manga(from: envelope.data, api: api)
    }

    /// MangaDex caps the feed at 500 rows per request and `offset + limit` at
    /// 10,000, so the feed is walked in pages.
    func chapters(mangaId: String) async throws -> [Chapter] {
        let limit = MangaDexAPI.chapterFeedPageSize
        var offset = 0
        var chapters: [Chapter] = []
        while offset < 9_500 {
            let request = api.chaptersRequest(mangaId: mangaId, offset: offset, limit: limit, configuration: configuration)
            let envelope: MDEnvelope<[MDEntity<MDChapterAttributes>]> = try await perform(request)
            chapters.append(contentsOf: envelope.data.compactMap { entity in
                entity.attributes.map { _ in MangaDexMapper.chapter(from: entity, mangaId: mangaId) }
            })
            offset += limit
            if envelope.data.count < limit { break }
        }
        return chapters
    }

    func pages(chapterId: String) async throws -> [Page] {
        let atHome: MDAtHome = try await perform(api.atHomeRequest(chapterId: chapterId))
        let pages = MangaDexMapper.pages(from: atHome, quality: configuration.quality)
        if pages.isEmpty {
            throw MangaSourceError.notFound
        }
        return pages
    }

    func filters() async throws -> [MangaFilter] {
        MangaDexAPI.filterDescriptors()
    }

    // MARK: - Private

    private func mangaList(_ request: URLRequest) async throws -> PagedResult<Manga> {
        let envelope: MDEnvelope<[MDEntity<MDMangaAttributes>]> = try await perform(request)
        let items = envelope.data.compactMap { try? MangaDexMapper.manga(from: $0, api: api) }
        let offset = envelope.offset ?? 0
        let limit = envelope.limit ?? items.count
        let hasNext = envelope.total.map { offset + limit < $0 } ?? (envelope.data.count >= limit)
        return PagedResult(items: items, hasNextPage: hasNext, totalCount: envelope.total)
    }

    private func perform<T: Decodable & Sendable>(_ request: URLRequest) async throws -> T {
        do {
            return try await client.send(T.self, for: request, decoder: HTTPClient.makeDecoder())
        } catch let error as HTTPError {
            throw error.asSourceError
        } catch is CancellationError {
            throw MangaSourceError.cancelled
        } catch let error as MangaSourceError {
            throw error
        } catch {
            throw MangaSourceError.network(error.localizedDescription)
        }
    }
}
