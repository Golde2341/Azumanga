import Foundation

/// Serves imported local manga through the ordinary source protocol, so the detail
/// screen, the reader and progress tracking need no special cases — pages come back
/// as file URLs, which the image pipeline already reads.
///
/// Registered disabled: `SourceRegistry.source(id:)` resolves it for the detail and
/// reader paths, while Browse and Global Search only look at enabled sources.
actor LocalLibrarySource: MangaSource {
    nonisolated static let sourceId = "local.library"

    nonisolated let id = LocalLibrarySource.sourceId
    nonisolated let name = "Local Library"
    nonisolated let version = "1.0.0"
    nonisolated let language = "en"
    nonisolated let isBuiltIn = true
    /// No `.search`, `.popular` or `.latest`: imported manga never contribute to
    /// discovery, only to the Library.
    nonisolated let capabilities: Set<SourceCapability> = [.chapters, .pages]

    private let store: LocalLibraryStore

    init(store: LocalLibraryStore = LocalLibraryStore()) {
        self.store = store
    }

    /// Imported manga are found in the Library, never by searching a provider.
    func search(_ query: String, page: Int, filters: [MangaFilterValue]) async throws -> PagedResult<Manga> {
        throw MangaSourceError.unsupported
    }

    func mangaDetails(id mangaId: String) async throws -> Manga {
        guard let manga = store.manga(id: mangaId) else { throw MangaSourceError.notFound }
        return manga
    }

    func chapters(mangaId: String) async throws -> [Chapter] {
        let entries = store.chapters(mangaId)
        guard !entries.isEmpty else { throw MangaSourceError.notFound }
        return entries.map { store.chapter(sourceId: id, mangaId: mangaId, entry: $0) }
    }

    func pages(chapterId: String) async throws -> [Page] {
        // The protocol hands pages(chapterId:) no manga id, so the owning manga is
        // found by looking through the chapter indexes on disk.
        guard let mangaId = mangaId(containingChapter: chapterId) else {
            throw MangaSourceError.notFound
        }

        let urls = try await store.pageURLs(mangaId: mangaId, chapterId: chapterId)
        return urls.enumerated().map { Page(index: $0.offset, url: $0.element) }
    }

    private func mangaId(containingChapter chapterId: String) -> String? {
        store.mangaIds().first { mangaId in
            store.chapters(mangaId).contains { $0.id == chapterId }
        }
    }
}
