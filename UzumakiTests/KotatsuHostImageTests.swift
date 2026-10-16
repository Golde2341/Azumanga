import CoreGraphics
import Foundation
import Testing
@testable import Uzumaki

/// A resolver that hands back a pre-written file, standing in for the parser host.
private actor StubHostResolver: HostImageResolving {
    private let file: URL
    private(set) var requests: [(sourceKey: String, remote: URL)] = []

    init(file: URL) {
        self.file = file
    }

    func localImageFile(sourceKey: String, remote: URL) async throws -> URL {
        requests.append((sourceKey, remote))
        return file
    }

    func imageData(sourceKey: String, remote: URL) async throws -> Data {
        try Data(contentsOf: try await localImageFile(sourceKey: sourceKey, remote: remote))
    }

    var recorded: [(sourceKey: String, remote: URL)] { requests }
}

@Suite("Host image routing")
struct KotatsuHostImageTests {
    // MARK: - URL round trip

    @Test("Host image URLs round-trip, preserving case and query strings")
    func roundTrip() throws {
        let remote = try #require(URL(string: "https://cdn.example.com/a/b/1.jpg?t=1668064755&x=%20y"))

        let wrapped = try #require(HostImageURL.make(sourceKey: "MANGAPILL", remote: remote))
        #expect(wrapped.scheme == "kotatsu-image")

        let parsed = try #require(HostImageURL.parse(wrapped))
        #expect(parsed.sourceKey == "MANGAPILL")  // case must survive: URL lowercases hosts
        #expect(parsed.remote == remote)
        #expect(HostImageURL.isHostImage(wrapped))
    }

    @Test("Ordinary and malformed URLs are not treated as host images")
    func rejectsNonHostURLs() throws {
        #expect(HostImageURL.parse(try #require(URL(string: "https://example.com/a.jpg"))) == nil)
        #expect(HostImageURL.parse(try #require(URL(string: "file:///tmp/a.jpg"))) == nil)
        // Right scheme, wrong shape.
        #expect(HostImageURL.parse(try #require(URL(string: "kotatsu-image://parser/only-one-part"))) == nil)
        #expect(!HostImageURL.isHostImage(try #require(URL(string: "https://example.com/a.jpg"))))
    }

    // MARK: - Pipeline

    private func makePipeline(resolver: (any HostImageResolving)?) -> (ImagePipeline, DiskImageCache) {
        let disk = DiskImageCache(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("uzumaki-host-images-\(UUID().uuidString)", isDirectory: true)
        )
        let client = HTTPClient(
            session: StubURLProtocol.makeSession(),
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: 0.01, maxDelay: 0.02, jitter: 0)
        )
        let pipeline = ImagePipeline(
            http: client,
            memory: MemoryImageCache(byteLimit: 8 * 1024 * 1024),
            disk: disk,
            hostResolver: resolver
        )
        return (pipeline, disk)
    }

    @Test("A host image is fetched via the resolver and cached under its logical URL")
    func resolvesThroughHost() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uzumaki-host-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let png = makePNGData(width: 400, height: 600)
        let file = directory.appendingPathComponent("page.png")
        try png.write(to: file)

        let resolver = StubHostResolver(file: file)
        let (pipeline, disk) = makePipeline(resolver: resolver)

        let remote = try #require(URL(string: "https://cdn.example.com/Manga/1.jpg"))
        let wrapped = try #require(HostImageURL.make(sourceKey: "MANGAPILL", remote: remote))

        let image = try await pipeline.image(for: wrapped, maxPixelSize: 120)
        #expect(max(image.width, image.height) <= 120)

        // The resolver saw the underlying remote URL, not the wrapper.
        let recorded = await resolver.recorded
        #expect(recorded.count == 1)
        #expect(recorded.first?.sourceKey == "MANGAPILL")
        #expect(recorded.first?.remote == remote)

        // Bytes are cached against the logical URL, so a second read is a hit.
        #expect(disk.data(forKey: DiskImageCache.key(for: wrapped)) == png)

        _ = try await pipeline.image(for: wrapped, maxPixelSize: 120)
        let afterSecondRead = await resolver.recorded
        #expect(afterSecondRead.count == 1, "the second read should come from cache, not the host")
    }

    @Test("A host image fails clearly when no resolver is configured")
    func missingResolver() async throws {
        let (pipeline, _) = makePipeline(resolver: nil)
        let wrapped = try #require(HostImageURL.make(sourceKey: "MANGAPILL", remote: URL(string: "https://cdn.example.com/1.jpg")!))

        do {
            _ = try await pipeline.image(for: wrapped, maxPixelSize: 64)
            Issue.record("expected the image to fail without a resolver")
        } catch let error as MangaSourceError {
            #expect((error.errorDescription ?? "").contains("parser host"))
        }
    }

    @Test("A resolver that produces nothing surfaces a decoding error")
    func emptyResolverOutput() async throws {
        let (pipeline, _) = makePipeline(resolver: StubHostResolver(file: URL(fileURLWithPath: "/nonexistent/none.png")))
        let wrapped = try #require(HostImageURL.make(sourceKey: "MANGAPILL", remote: URL(string: "https://cdn.example.com/1.jpg")!))

        await #expect(throws: MangaSourceError.self) {
            _ = try await pipeline.image(for: wrapped, maxPixelSize: 64)
        }
    }
}
