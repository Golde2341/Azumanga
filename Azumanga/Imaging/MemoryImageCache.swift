import CoreGraphics
import Foundation

/// Bounded in-memory image cache. Cost is the decoded pixel size in bytes, so
/// the limit reflects actual memory pressure rather than image count.
nonisolated final class MemoryImageCache: @unchecked Sendable {
    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()
    private let byteLimit: Int
    /// NSCache cannot be searched, so the keys it holds are tracked here. That is
    /// what lets one image (and all of its render sizes) be evicted.
    private let lock = NSLock()
    private var keys: Set<String> = []

    init(byteLimit: Int = 256 * 1024 * 1024) {
        self.byteLimit = byteLimit
        cache.totalCostLimit = byteLimit
    }

    func image(forKey key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func insert(_ image: CGImage, forKey key: String) {
        cache.setObject(Box(image), forKey: key as NSString, cost: Self.cost(of: image))
        lock.lock()
        keys.insert(key)
        lock.unlock()
    }

    /// Drops every cached size of the images whose keys start with `prefix`.
    func removeAll(withPrefix prefix: String) {
        lock.lock()
        let matching = keys.filter { $0.hasPrefix(prefix) }
        for key in matching { keys.remove(key) }
        lock.unlock()

        for key in matching {
            cache.removeObject(forKey: key as NSString)
        }
    }

    func removeAll() {
        cache.removeAllObjects()
        lock.lock()
        keys.removeAll()
        lock.unlock()
    }

    static func cost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }
}
