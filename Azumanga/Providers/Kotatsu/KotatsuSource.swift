import Foundation

/// A Kotatsu source, exposed to the rest of the app as an ordinary `MangaSource`.
///
/// Everything goes through the parser host, so nothing above this file knows a JVM
/// is involved. Three details are specific to Kotatsu and shaped this adapter:
///
///  * **Chapters come from `getDetails`.** There is no separate chapter call, and
///    `MangaDetailModel` requests details and chapters *concurrently* — so both go
///    through one deduplicated call instead of hitting the site twice.
///  * **Images must be fetched by the host.** Page and cover URLs are wrapped in
///    `HostImageURL`, so `ImagePipeline` routes them back through the parser, which
///    supplies the `Referer`, cookies and descrambling the CDNs require.
///  * **The parsers are handed back the objects they produced.** `getDetails` and
///    `getPages` take the `Manga`/`MangaChapter` they originally returned, so what
///    we decode is cached and sent back.
actor KotatsuSource: MangaSource, SourceProbing {
    nonisolated let id: String
    nonisolated let name: String
    nonisolated let version: String
    nonisolated let language: String
    nonisolated let contentType: String
    nonisolated let isBuiltIn = false
    nonisolated var providerKind: SourceProviderKind { .kotatsuHost }
    nonisolated let capabilities: Set<SourceCapability> = [
        .search, .popular, .latest, .filters, .chapters, .pages,
    ]

    private let host: any KotatsuHostCalling
    private let sourceKey: String
    private let callTimeout: Duration
    private let catalogFile: URL?

    // Session caches. The parser host keeps its own parser instances, but it has no
    // memory of what we asked for, so the objects live here.
    private var detailsTasks: [String: Task<KotatsuMangaDTO, any Error>] = [:]
    private var mangaCache: [String: KotatsuMangaDTO] = [:]
    private var chapterIndex: [String: KotatsuChapterDTO] = [:]
    private var filterOptionsCache: KotatsuFilterOptionsDTO?
    private var catalogLoaded = false

    init(
        source: KotatsuSourceDTO,
        host: any KotatsuHostCalling,
        catalogDirectory: URL? = KotatsuSource.defaultCatalogDirectory,
        callTimeout: Duration = .seconds(120)
    ) {
        self.sourceKey = source.key
        self.id = "kotatsu.\(source.key)"
        self.name = source.title
        self.version = "kotatsu-1.0"
        self.language = source.locale.isEmpty ? "multi" : source.locale
        self.contentType = source.contentType.isEmpty ? "MANGA" : source.contentType
        self.host = host
        self.callTimeout = callTimeout
        self.catalogFile = catalogDirectory?
            .appendingPathComponent("\(source.key).catalog.json", isDirectory: false)
    }

    // MARK: - Listing

    func popular(page: Int) async throws -> PagedResult<Manga> {
        try await list(page: page, sort: nil, query: nil, filters: [])
    }

    func latest(page: Int) async throws -> PagedResult<Manga> {
        // Without a hint the host falls back to the parser's first sort order, which
        // is usually popularity — so "Latest" would look identical to "Popular".
        let preferred = await preferredSortOrders()
            .first { Self.latestSortNames.contains($0) }
        return try await list(page: page, sort: preferred, query: nil, filters: [])
    }

    func search(_ query: String, page: Int, filters: [MangaFilterValue]) async throws -> PagedResult<Manga> {
        try await list(page: page, sort: nil, query: query, filters: filters)
    }

    private func list(
        page: Int,
        sort: String?,
        query: String?,
        filters: [MangaFilterValue],
        timeout: Duration? = nil
    ) async throws -> PagedResult<Manga> {
        var parameters = KotatsuListParameters(key: sourceKey, offset: max(0, page) * Self.pageSize)
        parameters.query = query?.nilIfBlank
        parameters.sort = sort?.nilIfBlank

        for filter in filters {
            switch (filter.filterId, filter.kind) {
            case ("sort", .select(let value)):
                parameters.sort = value.nilIfBlank ?? parameters.sort
            case ("states", .multiSelect(let values)):
                parameters.states = values
            case ("contentRatings", .multiSelect(let values)):
                parameters.contentRatings = values
            case ("types", .multiSelect(let values)):
                parameters.types = values
            case ("demographics", .multiSelect(let values)):
                parameters.demographics = values
            case ("yearFrom", .text(let value)):
                parameters.yearFrom = Int(value)
            case ("yearTo", .text(let value)):
                parameters.yearTo = Int(value)
            case ("author", .text(let value)):
                parameters.author = value.nilIfBlank
            default:
                break
            }
        }

        let response = try await host.call(
            "list",
            parameters: parameters,
            as: KotatsuMangaListDTO.self,
            timeout: timeout ?? callTimeout
        )

        // Remember the payloads: the parsers need them back for details and pages.
        for dto in response.items {
            remember(dto)
        }

        return PagedResult(
            items: response.items.map { KotatsuMapper.manga($0, sourceId: id, sourceKey: sourceKey) },
            // The host has no reliable "has more" signal; the discovery model stops
            // paging once a page contributes nothing new.
            hasNextPage: !response.items.isEmpty,
            totalCount: nil
        )
    }

    // MARK: - Details

    func mangaDetails(id mangaId: String) async throws -> Manga {
        let dto = try await details(for: mangaId)
        return KotatsuMapper.manga(dto, sourceId: id, sourceKey: sourceKey)
    }

    func chapters(mangaId: String) async throws -> [Chapter] {
        let dto = try await details(for: mangaId)
        return (dto.chapters ?? []).map {
            KotatsuMapper.chapter($0, sourceId: id, mangaId: mangaId, language: language)
        }
    }

    /// One shared fetch for details and chapters, cached for the session.
    private func details(for mangaId: String) async throws -> KotatsuMangaDTO {
        loadCatalogIfNeeded()
        if let cached = mangaCache[mangaId], cached.chapters != nil {
            return cached
        }
        if let running = detailsTasks[mangaId] {
            return try await running.value
        }

        let fallback = mangaCache[mangaId] ?? Self.minimalManga(id: mangaId)
        let parameters = KotatsuDetailsParameters(key: sourceKey, manga: fallback)
        let host = self.host
        let timeout = callTimeout

        let task = Task<KotatsuMangaDTO, any Error> {
            try await host.call(
                "details",
                parameters: parameters,
                as: KotatsuMangaDTO.self,
                timeout: timeout
            )
        }
        detailsTasks[mangaId] = task
        defer { detailsTasks[mangaId] = nil }

        let result = try await task.value
        remember(result)
        return result
    }

    /// Remembers a manga, its chapters, and writes it to the catalog.
    ///
    /// The catalog matters because the parsers need the original `Manga` back to
    /// fetch details and pages. Without it, reopening a title from the Library after
    /// a relaunch would send the parser an id with no URL and fail.
    private func remember(_ dto: KotatsuMangaDTO) {
        mangaCache[String(dto.id)] = dto
        for chapter in dto.chapters ?? [] {
            chapterIndex[String(chapter.id)] = chapter
        }
        // Only details carry chapters, so that is what is worth persisting.
        guard dto.chapters != nil else { return }
        persistCatalog()
    }

    private func loadCatalogIfNeeded() {
        guard !catalogLoaded else { return }
        catalogLoaded = true
        guard let catalogFile,
              let data = try? Data(contentsOf: catalogFile),
              let stored = try? JSONDecoder().decode([KotatsuMangaDTO].self, from: data)
        else { return }

        for dto in stored.prefix(Self.catalogLimit) {
            mangaCache[String(dto.id)] = dto
            for chapter in dto.chapters ?? [] {
                chapterIndex[String(chapter.id)] = chapter
            }
        }
    }

    private func persistCatalog() {
        guard let catalogFile else { return }
        let entries = Array(mangaCache.values.prefix(Self.catalogLimit))
        do {
            try FileManager.default.createDirectory(
                at: catalogFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            try encoder.encode(entries).write(to: catalogFile, options: .atomic)
        } catch {
            // A cache write failure must never break reading.
        }
    }

    // MARK: - Pages

    func pages(chapterId: String) async throws -> [Page] {
        // A chapter can be reached after a relaunch (library → chapter), in which
        // case the catalog on disk is the only record of it.
        loadCatalogIfNeeded()

        // `getPages` expects the chapter object the parser produced; it arrives with
        // the details for the manga the user opened.
        guard let chapter = chapterIndex[chapterId] else {
            throw MangaSourceError.provider(
                "This chapter has not been loaded yet. Open the manga again and retry."
            )
        }

        let response = try await host.call(
            "pages",
            parameters: KotatsuPagesParameters(key: sourceKey, chapter: chapter),
            as: KotatsuPageListDTO.self,
            timeout: callTimeout
        )

        let pages = KotatsuMapper.pages(response.items, sourceKey: sourceKey)
        if pages.isEmpty {
            throw MangaSourceError.notFound
        }
        return pages
    }

    // MARK: - Filters

    func filters() async throws -> [MangaFilter] {
        KotatsuMapper.filters(from: try await filterOptions())
    }

    private func filterOptions() async throws -> KotatsuFilterOptionsDTO {
        if let cached = filterOptionsCache { return cached }
        let options = try await host.call(
            "filterOptions",
            parameters: Optional<EmptyParameters>.none,
            as: KotatsuFilterOptionsDTO.self,
            timeout: callTimeout
        )
        filterOptionsCache = options
        return options
    }

    private func preferredSortOrders() async -> [String] {
        (try? await filterOptions().sortOrders) ?? []
    }

    // MARK: - Health

    /// A short-timeout listing, used by the bulk source check. The timeout is passed
    /// to the host too, so a hanging site cannot stall the host's request loop.
    nonisolated var probeTimeout: Duration { .seconds(25) }

    func probe() async throws -> Int {
        let page = try await list(page: 0, sort: nil, query: nil, filters: [], timeout: probeTimeout)
        if page.items.isEmpty {
            throw MangaSourceError.notFound
        }
        return page.items.count
    }

    // MARK: - Helpers

    /// Kotatsu's parsers size their own pages; this is only an offset multiplier.
    private static let pageSize = 30

    /// How many manga to keep on disk per source.
    private static let catalogLimit = 500

    /// Where the per-source catalog of opened titles lives.
    static var defaultCatalogDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Azumanga/KotatsuCatalog", isDirectory: true)
    }

    private static let latestSortNames: Set<String> = [
        "UPDATED", "UPDATED_DESC", "NEWEST", "NEWEST_DESC", "ADDED", "ADDED_DESC",
    ]

    /// Used when a manga is opened without a preceding list call (for example from
    /// the library). The parser gets the id; ones that also need the page URL will
    /// report their own error, which is better than inventing one.
    private static func minimalManga(id: String) -> KotatsuMangaDTO {
        KotatsuMangaDTO(
            id: Int64(id) ?? 0,
            title: "",
            altTitles: nil,
            url: "",
            publicUrl: nil,
            rating: nil,
            coverUrl: nil,
            largeCoverUrl: nil,
            description: nil,
            state: nil,
            contentRating: nil,
            sourceKey: nil,
            authors: nil,
            tags: nil,
            chapters: nil
        )
    }
}
