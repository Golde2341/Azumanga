import Foundation

/// Metadata for an imported local manga, persisted as `metadata.json` beside the
/// imported files. Living on disk rather than in SwiftData means the library needs
/// no new model and no migration: the library row is an ordinary `LibraryEntry`,
/// and the description and cover are read back by the local source.
nonisolated struct LocalMangaMetadata: Codable, Sendable, Equatable {
    var title: String
    var description: String?
    var author: String?
    var artist: String?
    var year: Int?
    var statusRaw: String
    var genres: [String]
    /// File name of the cover image inside the manga folder, when one is set.
    var coverFileName: String?
    var webURLString: String?

    init(
        title: String,
        description: String? = nil,
        author: String? = nil,
        artist: String? = nil,
        year: Int? = nil,
        status: PublicationStatus = .unknown,
        genres: [String] = [],
        coverFileName: String? = nil,
        webURLString: String? = nil
    ) {
        self.title = title
        self.description = description
        self.author = author
        self.artist = artist
        self.year = year
        self.statusRaw = status.rawValue
        self.genres = genres
        self.coverFileName = coverFileName
        self.webURLString = webURLString
    }

    var status: PublicationStatus {
        get { PublicationStatus(rawValue: statusRaw) ?? .unknown }
        set { statusRaw = newValue.rawValue }
    }
}

/// One imported chapter: an imported file (CBZ or PDF) and the name it is shown
/// under. `number` is
/// the chapter's position in the reader's order, which is what makes a manual
/// reorder stick — `Chapter.readingOrder` sorts by number.
nonisolated struct LocalChapterEntry: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var fileName: String
    var title: String
    var number: Double
    var order: Int
}

/// Reads and writes the imported-manga folder tree under Application Support.
///
/// Layout, mirroring `DownloadDirectories`:
///
///     LocalLibrary/<mangaId>/metadata.json
///     LocalLibrary/<mangaId>/chapters.json
///     LocalLibrary/<mangaId>/chapters/<original name>.cbz
///     LocalLibrary/<mangaId>/pages/<chapterId>/…      (extracted, cache)
///     LocalLibrary/<mangaId>/cover.<ext>
nonisolated struct LocalLibraryStore: Sendable {
    let root: URL

    /// Imported manga live in Documents/azumanga beside downloaded chapters.
    static var defaultRoot: URL {
        AppDirectories.documents("LocalLibrary")
    }

    /// Bumped whenever the page rasteriser changes, so pages unpacked by an older
    /// build are rebuilt instead of being reused.
    static let pageRenderVersion = "2"
    private static let renderVersionFile = ".render-version"

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif", "avif", "bmp", "heic", "tiff", "tif",
    ]

    init(root: URL = LocalLibraryStore.defaultRoot) {
        self.root = root
    }

    // MARK: - Paths

    func mangaDirectory(_ mangaId: String) -> URL {
        root.appendingPathComponent(DownloadDirectories.sanitize(mangaId), isDirectory: true)
    }

    func chaptersDirectory(_ mangaId: String) -> URL {
        mangaDirectory(mangaId).appendingPathComponent("chapters", isDirectory: true)
    }

    func pagesDirectory(mangaId: String, chapterId: String) -> URL {
        mangaDirectory(mangaId)
            .appendingPathComponent("pages", isDirectory: true)
            .appendingPathComponent(DownloadDirectories.sanitize(chapterId), isDirectory: true)
    }

    func metadataFile(_ mangaId: String) -> URL {
        mangaDirectory(mangaId).appendingPathComponent("metadata.json")
    }

    func chaptersFile(_ mangaId: String) -> URL {
        mangaDirectory(mangaId).appendingPathComponent("chapters.json")
    }

    /// The imported file for a chapter — a CBZ or a PDF.
    func chapterFile(mangaId: String, fileName: String) -> URL {
        chaptersDirectory(mangaId).appendingPathComponent(DownloadDirectories.sanitize(fileName))
    }

    func coverURL(mangaId: String) -> URL? {
        coverURL(mangaId: mangaId, fileName: metadata(mangaId)?.coverFileName)
    }

    // MARK: - Reading

    func mangaIds() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
    }

    func metadata(_ mangaId: String) -> LocalMangaMetadata? {
        guard let data = try? Data(contentsOf: metadataFile(mangaId)) else { return nil }
        return try? JSONDecoder().decode(LocalMangaMetadata.self, from: data)
    }

    /// The chapter list in reading order.
    func chapters(_ mangaId: String) -> [LocalChapterEntry] {
        guard let data = try? Data(contentsOf: chaptersFile(mangaId)),
              let list = try? JSONDecoder().decode([LocalChapterEntry].self, from: data)
        else { return [] }

        return list.sorted { $0.order < $1.order }
    }

    func manga(id mangaId: String) -> Manga? {
        guard let metadata = metadata(mangaId) else { return nil }

        return Manga(
            sourceId: LocalLibrarySource.sourceId,
            mangaId: mangaId,
            title: metadata.title,
            description: metadata.description,
            coverURL: coverURL(mangaId: mangaId, fileName: metadata.coverFileName),
            author: metadata.author,
            artist: metadata.artist,
            status: metadata.status,
            genres: metadata.genres,
            year: metadata.year,
            webURL: metadata.webURLString.flatMap(URL.init(string:))
        )
    }

    func chapter(sourceId: String, mangaId: String, entry: LocalChapterEntry) -> Chapter {
        Chapter(
            sourceId: sourceId,
            mangaId: mangaId,
            chapterId: entry.id,
            title: entry.title,
            number: entry.number
        )
    }

    // MARK: - Writing

    func saveMetadata(_ metadata: LocalMangaMetadata, mangaId: String) throws {
        try FileManager.default.createDirectory(
            at: mangaDirectory(mangaId),
            withIntermediateDirectories: true
        )
        try Self.encode(metadata).write(to: metadataFile(mangaId), options: .atomic)
    }

    func saveChapters(_ chapters: [LocalChapterEntry], mangaId: String) throws {
        try FileManager.default.createDirectory(
            at: mangaDirectory(mangaId),
            withIntermediateDirectories: true
        )
        let ordered = chapters.enumerated().map { index, entry in
            var entry = entry
            entry.order = index
            entry.number = Double(index + 1)
            return entry
        }
        try Self.encode(ordered).write(to: chaptersFile(mangaId), options: .atomic)
    }

    /// Copies the chosen CBZ files in, writes the metadata, and returns the new
    /// manga value. Chapters are ordered by natural file name.
    func createManga(
        title: String,
        description: String?,
        author: String?,
        artist: String?,
        genres: [String],
        status: PublicationStatus,
        cover: LocalCoverSource?,
        files: [URL]
    ) throws -> (manga: Manga, chapters: [LocalChapterEntry]) {
        let mangaId = UUID().uuidString
        let directory = chaptersDirectory(mangaId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: mangaDirectory(mangaId),
            withIntermediateDirectories: true
        )

        var used = Set<String>()
        var entries: [LocalChapterEntry] = []

        for file in Self.naturalSorted(files) {
            let name = Self.uniqueName(file.lastPathComponent, used: &used)
            try copyIntoLibrary(from: file, to: directory.appendingPathComponent(name))
            entries.append(
                LocalChapterEntry(
                    id: UUID().uuidString,
                    fileName: name,
                    title: Self.chapterTitle(from: file.lastPathComponent),
                    number: Double(entries.count + 1),
                    order: entries.count
                )
            )
        }

        var metadata = LocalMangaMetadata(
            title: title,
            description: description,
            author: author,
            artist: artist,
            status: status,
            genres: genres
        )

        if case let .file(url) = cover {
            metadata.coverFileName = try copyCover(from: url, mangaId: mangaId)
        }

        try saveMetadata(metadata, mangaId: mangaId)
        try saveChapters(entries, mangaId: mangaId)

        let manga = Manga(
            sourceId: LocalLibrarySource.sourceId,
            mangaId: mangaId,
            title: title,
            description: description,
            coverURL: coverURL(mangaId: mangaId, fileName: metadata.coverFileName),
            author: author,
            artist: artist,
            status: status,
            genres: genres
        )
        return (manga, entries)
    }

    /// Rewrites the metadata and chapter order of an existing import.
    func updateManga(
        mangaId: String,
        title: String,
        description: String?,
        author: String?,
        artist: String?,
        genres: [String],
        status: PublicationStatus,
        cover: LocalCoverSource?,
        chapters: [LocalChapterEntry]
    ) throws -> Manga {
        var metadata = metadata(mangaId) ?? LocalMangaMetadata(title: title)
        metadata.title = title
        metadata.description = description
        metadata.author = author
        metadata.artist = artist
        metadata.genres = genres
        metadata.status = status

        switch cover {
        case let .file(url):
            metadata.coverFileName = try copyCover(from: url, mangaId: mangaId)
        case .remove:
            removeCover(mangaId: mangaId)
            metadata.coverFileName = nil
        case .keep, .none:
            break
        }

        try saveMetadata(metadata, mangaId: mangaId)
        try saveChapters(chapters, mangaId: mangaId)

        guard let manga = manga(id: mangaId) else { throw MangaSourceError.notFound }
        return manga
    }

    /// Writes cover bytes that were fetched from a source during metadata search.
    @discardableResult
    func writeCover(_ data: Data, fileExtension: String, mangaId: String) throws -> String {
        try FileManager.default.createDirectory(
            at: mangaDirectory(mangaId),
            withIntermediateDirectories: true
        )
        let name = "cover.\(Self.imageExtensions.contains(fileExtension.lowercased()) ? fileExtension.lowercased() : "jpg")"
        try removeOtherCovers(mangaId: mangaId, keeping: name)
        try data.write(to: mangaDirectory(mangaId).appendingPathComponent(name), options: .atomic)
        return name
    }

    @discardableResult
    func copyCover(from source: URL, mangaId: String) throws -> String {
        let fileExtension = Self.imageExtensions.contains(source.pathExtension.lowercased())
            ? source.pathExtension.lowercased()
            : "jpg"
        let name = "cover.\(fileExtension)"
        try FileManager.default.createDirectory(
            at: mangaDirectory(mangaId),
            withIntermediateDirectories: true
        )
        try removeOtherCovers(mangaId: mangaId, keeping: name)
        try copyIntoLibrary(from: source, to: mangaDirectory(mangaId).appendingPathComponent(name))
        return name
    }

    /// Removes an import and everything it put on disk.
    func deleteManga(id mangaId: String) {
        try? FileManager.default.removeItem(at: mangaDirectory(mangaId))
    }

    /// Imports dropped files or folders straight into the library.
    ///
    /// A dropped folder becomes one manga whose chapters are the CBZ/PDF files inside
    /// it; loose files are grouped into a single manga. Nothing is asked, so dropping
    /// a batch is a one-step import.
    func importDropped(_ urls: [URL]) throws -> [Manga] {
        // Hold every drop's security scope for the whole import: the files are copied
        // later, and a folder's children are only readable while its scope is held.
        let scopes = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer {
            for (url, active) in scopes where active {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var mangas: [Manga] = []
        var loose: [URL] = []

        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }

            if isDirectory.boolValue {
                let files = Self.chapterFiles(in: url)
                guard !files.isEmpty else { continue }
                if let manga = try? createManga(
                    title: url.lastPathComponent,
                    description: nil,
                    author: nil,
                    artist: nil,
                    genres: [],
                    status: .unknown,
                    cover: nil,
                    files: files
                ).manga {
                    mangas.append(manga)
                }
            } else if Self.isChapterFile(url) {
                loose.append(url)
            }
        }

        if !loose.isEmpty {
            let sorted = Self.naturalSorted(loose)
            let parent = sorted.first?.deletingLastPathComponent().lastPathComponent ?? ""
            let title = parent.isEmpty ? "Imported manga" : parent
            if let manga = try? createManga(
                title: title,
                description: nil,
                author: nil,
                artist: nil,
                genres: [],
                status: .unknown,
                cover: nil,
                files: sorted
            ).manga {
                mangas.append(manga)
            }
        }

        return mangas
    }

    static func isChapterFile(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return fileExtension == "cbz" || fileExtension == "pdf"
    }

    /// Every CBZ/PDF under a folder, in natural name order.
    static func chapterFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard !url.pathComponents.contains("__MACOSX") else { continue }
            guard isChapterFile(url) else { continue }
            files.append(url)
        }
        return naturalSorted(files)
    }

    /// Points the metadata at a cover file that was just written.
    func setCoverFileName(_ fileName: String?, mangaId: String) throws {
        guard var metadata = metadata(mangaId) else { return }
        metadata.coverFileName = fileName
        try saveMetadata(metadata, mangaId: mangaId)
    }

    func removeCover(mangaId: String) {
        for fileExtension in Self.imageExtensions {
            try? FileManager.default.removeItem(
                at: mangaDirectory(mangaId).appendingPathComponent("cover.\(fileExtension)")
            )
        }
    }

    // MARK: - Pages

    /// Page image URLs for a chapter, unpacking the file on first use.
    func pageURLs(mangaId: String, chapterId: String) async throws -> [URL] {
        let directory = pagesDirectory(mangaId: mangaId, chapterId: chapterId)
        var files = imageFiles(in: directory)

        if files.isEmpty || renderVersion(in: directory) != Self.pageRenderVersion {
            try await preparePages(mangaId: mangaId, chapterId: chapterId)
            files = imageFiles(in: directory)
        }

        guard !files.isEmpty else { throw MangaSourceError.notFound }
        return files
    }

    /// Unpacks a CBZ, or rasterises a PDF, into the chapter's page folder.
    private func preparePages(mangaId: String, chapterId: String) async throws {
        guard let entry = chapters(mangaId).first(where: { $0.id == chapterId }) else {
            throw MangaSourceError.notFound
        }

        let source = chapterFile(mangaId: mangaId, fileName: entry.fileName)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw MangaSourceError.notFound
        }

        let destination = pagesDirectory(mangaId: mangaId, chapterId: chapterId)
        try? FileManager.default.removeItem(at: destination)

        if LocalPDF.isPDF(source) {
            try LocalPDF.render(pdf: source, to: destination)
        } else {
            try await LocalArchive.extract(cbz: source, to: destination)
        }

        try? Self.pageRenderVersion.write(
            to: destination.appendingPathComponent(Self.renderVersionFile),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Which rasteriser produced a chapter's pages, if any.
    private func renderVersion(in directory: URL) -> String? {
        (try? String(
            contentsOf: directory.appendingPathComponent(Self.renderVersionFile),
            encoding: .utf8
        ))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every image under a directory, in natural name order. Archive layouts vary,
    /// so this recurses and ignores the metadata folders `ditto` leaves behind.
    func imageFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard !url.pathComponents.contains("__MACOSX") else { continue }
            guard LocalLibraryStore.imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
            files.append(url)
        }

        return Self.naturalSorted(files, by: { $0.path })
    }

    // MARK: - Helpers

    private func coverURL(mangaId: String, fileName: String?) -> URL? {
        guard let fileName, !fileName.isEmpty else { return nil }
        return mangaDirectory(mangaId).appendingPathComponent(fileName)
    }

    private func removeOtherCovers(mangaId: String, keeping name: String) throws {
        for fileExtension in LocalLibraryStore.imageExtensions where "cover.\(fileExtension)" != name {
            try? FileManager.default.removeItem(
                at: mangaDirectory(mangaId).appendingPathComponent("cover.\(fileExtension)")
            )
        }
    }

    private func copyIntoLibrary(from source: URL, to destination: URL) throws {
        // Files chosen through the importer or dropped on the sheet are only
        // readable while their security scope is held.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        let sanitized = DownloadDirectories.sanitize(name)
        guard used.contains(sanitized) else {
            used.insert(sanitized)
            return sanitized
        }

        let base = (sanitized as NSString).deletingPathExtension
        let ext = (sanitized as NSString).pathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            if !used.contains(candidate) {
                used.insert(candidate)
                return candidate
            }
            index += 1
        }
    }

    /// The chapter's display name: the file name without its extension.
    static func chapterTitle(from fileName: String) -> String {
        let title = (fileName as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? fileName : title
    }

    static func naturalSorted(_ urls: [URL]) -> [URL] {
        naturalSorted(urls, by: { $0.lastPathComponent })
    }

    static func naturalSorted(_ urls: [URL], by key: (URL) -> String) -> [URL] {
        urls.sorted { key($0).localizedStandardCompare(key($1)) == .orderedAscending }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
}

/// Where a cover image should come from when saving an import.
nonisolated enum LocalCoverSource: Sendable {
    /// A file the user chose; it is copied into the manga folder.
    case file(URL)
    /// Keep whatever cover the manga already has (editing only).
    case keep
    /// Drop the current cover (editing only).
    case remove
}

/// The cover choice a sheet is holding, before it is turned into a `LocalCoverSource`.
nonisolated enum LocalCoverChoice: Equatable, Sendable {
    /// Chosen from disk.
    case file(URL)
    /// Taken from a search result; fetched when the import is saved.
    case remote(URL)
    /// Explicitly cleared.
    case removed
}
