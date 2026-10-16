import Foundation

/// Adapts an installed JavaScript provider to the `MangaSource` protocol, so
/// nothing above this file knows whether a source is native or scripted.
actor JSProviderSource: MangaSource {
    nonisolated let id: String
    nonisolated let name: String
    nonisolated let version: String
    nonisolated let language: String
    nonisolated let isBuiltIn = false
    nonisolated let capabilities: Set<SourceCapability>
    nonisolated let manifest: SourceManifest

    private let host: JSProviderHost
    private let configuration: [String: String]
    private let decoder = JSONDecoder()

    init(
        manifest: SourceManifest,
        script: String,
        configuration: [String: String],
        http: HTTPClient,
        callTimeout: Duration = .seconds(30),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        self.manifest = manifest
        self.id = manifest.id
        self.name = manifest.name
        self.version = manifest.version
        self.language = manifest.language
        self.capabilities = Set(manifest.capabilities)
        self.configuration = configuration

        let providerId = manifest.id
        self.host = try JSProviderHost(
            manifest: manifest,
            script: script,
            configuration: configuration,
            http: http,
            callTimeout: callTimeout,
            log: { message in log("[\(providerId)] \(message)") }
        )
    }

    // MARK: - MangaSource

    func popular(page: Int) async throws -> PagedResult<Manga> {
        guard capabilities.contains(.popular) else { throw MangaSourceError.unsupported }
        return try await mangaList(method: "popular", arguments: [page])
    }

    func latest(page: Int) async throws -> PagedResult<Manga> {
        guard capabilities.contains(.latest) else { throw MangaSourceError.unsupported }
        return try await mangaList(method: "latest", arguments: [page])
    }

    func search(_ query: String, page: Int, filters: [MangaFilterValue]) async throws -> PagedResult<Manga> {
        guard capabilities.contains(.search) else { throw MangaSourceError.unsupported }
        return try await mangaList(
            method: "search",
            arguments: [query, page, JSProviderMapper.filterArguments(filters)]
        )
    }

    func mangaDetails(id mangaId: String) async throws -> Manga {
        let data = try await host.call("mangaDetails", arguments: [mangaId])
        let dto: JSProviderManga = try decode(data, method: "mangaDetails")
        return JSProviderMapper.manga(dto, sourceId: id)
    }

    func chapters(mangaId: String) async throws -> [Chapter] {
        let data = try await host.call("chapters", arguments: [mangaId])
        let list: JSProviderChapterList = try decode(data, method: "chapters")
        return list.items.map { JSProviderMapper.chapter($0, sourceId: id, mangaId: mangaId) }
    }

    func pages(chapterId: String) async throws -> [Page] {
        let data = try await host.call("pages", arguments: [chapterId])
        let list: JSProviderPageList = try decode(data, method: "pages")
        let pages = JSProviderMapper.pages(list.items)
        if pages.isEmpty {
            throw MangaSourceError.notFound
        }
        return pages
    }

    func filters() async throws -> [MangaFilter] {
        guard capabilities.contains(.filters) else { return [] }
        let data = try await host.call("filters", arguments: [])
        let list: JSProviderFilterList = try decode(data, method: "filters")
        return list.items.map(JSProviderMapper.filter)
    }

    // MARK: - Private

    private func mangaList(method: String, arguments: [Any]) async throws -> PagedResult<Manga> {
        let data = try await host.call(method, arguments: arguments)
        let list: JSProviderMangaList = try decode(data, method: method)
        return PagedResult(
            items: list.items.map { JSProviderMapper.manga($0, sourceId: id) },
            hasNextPage: list.hasNextPage ?? false,
            totalCount: list.total
        )
    }

    private func decode<T: Decodable>(_ data: Data, method: String) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw MangaSourceError.decoding("\(method)(): \(HTTPClient.describe(error))")
        }
    }
}
