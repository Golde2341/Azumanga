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

    init(byteLimit: Int = 256 * 1024 * 1024) {
        self.byteLimit = byteLimit
        cache.totalCostLimit = byteLimit
    }

    func image(forKey key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func insert(_ image: CGImage, forKey key: String) {
        cache.setObject(Box(image), forKey: key as NSString, cost: Self.cost(of: image))
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    static func cost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }
}
