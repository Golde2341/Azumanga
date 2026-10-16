import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Uzumaki

@Suite("ImagePipeline")
struct ImagePipelineTests {
    private func makePipeline() -> (ImagePipeline, DiskImageCache) {
        let disk = DiskImageCache(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("uzumaki-images-\(UUID().uuidString)", isDirectory: true)
        )
        let client = HTTPClient(
            session: StubURLProtocol.makeSession(),
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: 0.01, maxDelay: 0.02, jitter: 0)
        )
        let pipeline = ImagePipeline(http: client, memory: MemoryImageCache(byteLimit: 8 * 1024 * 1024), disk: disk)
        return (pipeline, disk)
    }

    nonisolated private func pngData(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!

        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test("Downloads, downsamples to the requested size and caches to disk")
    func loadsAndDownsamples() async throws {
        let host = StubURLProtocol.makeHost("img")
        let payload = pngData(width: 400, height: 600)
        StubURLProtocol.setHandler(for: host) { _ in
            StubURLProtocol.Response(statusCode: 200, headers: ["Content-Type": "image/png"], body: payload)
        }

        let (pipeline, disk) = makePipeline()
        let result = try await pipeline.load(url: URL(string: "https://\(host)/page.png")!, maxPixelSize: 120)

        #expect(max(result.image.width, result.image.height) <= 120)
        #expect(result.wasCached == false)
        #expect(result.byteCount == payload.count)
        #expect(StubURLProtocol.requests(for: host).count == 1)
        // Bytes are cached on disk exactly once, keyed by URL.
        #expect(disk.totalSize() == Int64(payload.count))
    }

    @Test("Second load is served from cache without another request")
    func memoryCacheHit() async throws {
        let host = StubURLProtocol.makeHost("cache")
        StubURLProtocol.setHandler(for: host) { _ in
            StubURLProtocol.Response(statusCode: 200, body: pngData(width: 200, height: 300))
        }

        let (pipeline, _) = makePipeline()
        let url = URL(string: "https://\(host)/cached.png")!

        _ = try await pipeline.load(url: url, maxPixelSize: 100)
        let second = try await pipeline.load(url: url, maxPixelSize: 100)

        #expect(second.wasCached)
        #expect(StubURLProtocol.requests(for: host).count == 1)
    }

    @Test("Concurrent requests for the same image share one download")
    func sharedInFlight() async throws {
        let host = StubURLProtocol.makeHost("shared")
        StubURLProtocol.setHandler(for: host) { _ in
            StubURLProtocol.Response(statusCode: 200, body: pngData(width: 300, height: 300))
        }

        let (pipeline, _) = makePipeline()
        let url = URL(string: "https://\(host)/shared.png")!

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    _ = try await pipeline.load(url: url, maxPixelSize: 128)
                }
            }
            try await group.waitForAll()
        }

        #expect(StubURLProtocol.requests(for: host).count == 1)
    }

    @Test("Surfaces a source error when the image is not decodable")
    func invalidImageData() async {
        let host = StubURLProtocol.makeHost("broken")
        StubURLProtocol.setHandler(for: host) { _ in
            StubURLProtocol.Response(statusCode: 200, body: Data("not an image".utf8))
        }
        let (pipeline, _) = makePipeline()

        await #expect(throws: MangaSourceError.self) {
            _ = try await pipeline.load(url: URL(string: "https://\(host)/broken.png")!, maxPixelSize: 64)
        }
    }

    @Test("Surfaces an error when the image request fails")
    func httpFailure() async {
        let host = StubURLProtocol.makeHost("missing")
        StubURLProtocol.setHandler(for: host) { _ in StubURLProtocol.Response(statusCode: 404) }
        let (pipeline, _) = makePipeline()

        await #expect(throws: MangaSourceError.self) {
            _ = try await pipeline.load(url: URL(string: "https://\(host)/missing.png")!, maxPixelSize: 64)
        }
    }

    @Test("Disk cache can be cleared")
    func clearDisk() async throws {
        let host = StubURLProtocol.makeHost("clear")
        StubURLProtocol.setHandler(for: host) { _ in
            StubURLProtocol.Response(statusCode: 200, body: pngData(width: 100, height: 100))
        }
        let (pipeline, disk) = makePipeline()

        _ = try await pipeline.load(url: URL(string: "https://\(host)/a.png")!, maxPixelSize: 50)
        #expect(disk.totalSize() > 0)

        await pipeline.clearDisk()
        #expect(disk.totalSize() == 0)
    }
}
