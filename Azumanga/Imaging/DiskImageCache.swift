import CryptoKit
import Foundation

/// File-backed cache for downloaded image bytes. The original encoded bytes are
/// stored once per URL, so requesting the same image at several render sizes does
/// not duplicate storage.
nonisolated final class DiskImageCache: @unchecked Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Azumanga/Images", isDirectory: true)
    }

    static func key(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func data(forKey key: String) -> Data? {
        try? Data(contentsOf: fileURL(for: key))
    }

    func store(_ data: Data, forKey key: String) {
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    func remove(forKey key: String) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func totalSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(key)
    }
}
