import Foundation

/// The single abstraction every manga provider implements — native Swift sources
/// (like MangaDex) and installed JavaScript sources alike. Views and business
/// logic depend only on this protocol, never on concrete providers.
///
/// Declared `nonisolated`: providers run off the main actor, and metadata is
/// exposed as `nonisolated` so it can be read from any context.
nonisolated protocol MangaSource: Sendable {
    /// Stable, reverse-DNS identifier, e.g. `org.mangadex`.
    nonisolated var id: String { get }
    /// Display name shown in the UI.
    nonisolated var name: String { get }
    /// Semantic version of the source implementation.
    nonisolated var version: String { get }
    /// BCP-47 language tag the source serves by default.
    nonisolated var language: String { get }
    /// Behaviours this source supports.
    nonisolated var capabilities: Set<SourceCapability> { get }
    /// `true` for sources compiled into the app, `false` for installed ones.
    nonisolated var isBuiltIn: Bool { get }

    func popular(page: Int) async throws -> PagedResult<Manga>
    func latest(page: Int) async throws -> PagedResult<Manga>
    func search(_ query: String, page: Int, filters: [MangaFilterValue]) async throws -> PagedResult<Manga>
    func mangaDetails(id: String) async throws -> Manga
    func chapters(mangaId: String) async throws -> [Chapter]
    func pages(chapterId: String) async throws -> [Page]
    func filters() async throws -> [MangaFilter]
}

nonisolated extension MangaSource {
    nonisolated var isBuiltIn: Bool { false }

    /// Sources default to no filters; overriding is optional.
    func filters() async throws -> [MangaFilter] { [] }

    func popular(page: Int) async throws -> PagedResult<Manga> { throw MangaSourceError.unsupported }
    func latest(page: Int) async throws -> PagedResult<Manga> { throw MangaSourceError.unsupported }

    nonisolated func supports(_ capability: SourceCapability) -> Bool {
        capabilities.contains(capability)
    }
}
