import Foundation

/// Identifies a chapter to download or read offline.
nonisolated struct DownloadJob: Sendable, Hashable {
    let sourceId: String
    let mangaId: String
    let mangaTitle: String
    let chapterId: String
    let chapterTitle: String?
    let chapterNumber: Double?
}

nonisolated struct DownloadProgress: Sendable, Equatable {
    let completedPages: Int
    let totalPages: Int
    let byteCount: Int64

    var fraction: Double {
        guard totalPages > 0 else { return 0 }
        return min(1, Double(completedPages) / Double(totalPages))
    }
}

nonisolated struct DownloadOutcome: Sendable, Equatable {
    let pageCount: Int
    let byteCount: Int64
}

/// Maps chapter identities onto directories under Application Support.
///
/// Source-supplied ids are untrusted (a provider can return anything), so every
/// path component is sanitised — a provider must never be able to write outside
/// its own download directory.
nonisolated struct DownloadDirectories: Sendable {
    let root: URL

    static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Uzumaki/Downloads", isDirectory: true)
    }

    init(root: URL = DownloadDirectories.defaultRoot) {
        self.root = root
    }

    func chapterDirectory(sourceId: String, mangaId: String, chapterId: String) -> URL {
        root
            .appendingPathComponent(Self.sanitize(sourceId), isDirectory: true)
            .appendingPathComponent(Self.sanitize(mangaId), isDirectory: true)
            .appendingPathComponent(Self.sanitize(chapterId), isDirectory: true)
    }

    func relativeName(sourceId: String, mangaId: String, chapterId: String) -> String {
        "\(Self.sanitize(sourceId))/\(Self.sanitize(mangaId))/\(Self.sanitize(chapterId))"
    }

    func pageFile(in directory: URL, index: Int, sourceURL: URL) -> URL {
        let suffix = Self.imageSuffix(for: sourceURL)
        return directory.appendingPathComponent(String(format: "%04d.%@", index, suffix))
    }

    /// Downloaded pages in index order, ready to be read offline.
    func pageFiles(in directory: URL) -> [(index: Int, url: URL)] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents.compactMap { url -> (Int, URL)? in
            guard let index = Int(url.deletingPathExtension().lastPathComponent) else { return nil }
            return (index, url)
        }
        .sorted { $0.0 < $1.0 }
        .map { (index: $0.0, url: $0.1) }
    }

    func byteCount(in directory: URL) -> Int64 {
        pageFiles(in: directory).reduce(into: Int64(0)) { total, file in
            let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
    }

    func removeChapter(sourceId: String, mangaId: String, chapterId: String) {
        try? FileManager.default.removeItem(at: chapterDirectory(sourceId: sourceId, mangaId: mangaId, chapterId: chapterId))
    }

    func totalSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Strips anything that could escape the download root or confuse a shell.
    static func sanitize(_ value: String) -> String {
        let cleaned = value.map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_" || character == ".")
                ? character
                : "_"
        }
        let result = String(cleaned.prefix(96))
        // "." and ".." are dangerous, and an empty name is useless.
        if result.isEmpty || result.allSatisfy({ $0 == "." }) {
            return "_"
        }
        return result
    }

    private static func imageSuffix(for url: URL) -> String {
        let suffix = url.pathExtension.lowercased()
        let allowed: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "avif", "bmp", "heic"]
        return allowed.contains(suffix) ? suffix : "img"
    }
}
