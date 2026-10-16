import CoreGraphics
import Foundation

nonisolated struct ImageLoadResult: Sendable {
    let image: CGImage
    let byteCount: Int
    let wasCached: Bool
}

/// Central image loader: memory cache → disk cache → network, with ImageIO
/// downsampling at every step. Concurrent requests for the same image share a
/// single download.
actor ImagePipeline {
    struct Key: Hashable, Sendable {
        let url: URL
        let maxPixelSize: Int

        var memoryKey: String { "\(DiskImageCache.key(for: url))@\(maxPixelSize)" }
        var diskKey: String { DiskImageCache.key(for: url) }
    }

    private let http: HTTPClient
    private let memory: MemoryImageCache
    private let disk: DiskImageCache
    /// Optional provider host used for images that the app must not fetch directly.
    private let hostResolver: (any HostImageResolving)?
    private var inFlight: [Key: Task<ImageLoadResult, any Error>] = [:]

    init(
        http: HTTPClient,
        memory: MemoryImageCache,
        disk: DiskImageCache,
        hostResolver: (any HostImageResolving)? = nil
    ) {
        self.http = http
        self.memory = memory
        self.disk = disk
        self.hostResolver = hostResolver
    }

    // MARK: - Loading

    func load(url: URL, maxPixelSize: Int) async throws -> ImageLoadResult {
        let key = Key(url: url, maxPixelSize: maxPixelSize)

        if let cached = memory.image(forKey: key.memoryKey) {
            return ImageLoadResult(image: cached, byteCount: MemoryImageCache.cost(of: cached), wasCached: true)
        }
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let http = http
        let memory = memory
        let disk = disk
        let hostResolver = hostResolver
        let task = Task<ImageLoadResult, any Error> {
            try await Self.fetch(
                url: url,
                key: key,
                http: http,
                memory: memory,
                disk: disk,
                hostResolver: hostResolver
            )
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        return try await task.value
    }

    func image(for url: URL, maxPixelSize: Int) async throws -> CGImage {
        try await load(url: url, maxPixelSize: maxPixelSize).image
    }

    /// Loads a page image and reports delivery health when the source asks for it.
    func image(for page: Page, maxPixelSize: Int) async throws -> CGImage {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let result = try await load(url: page.url, maxPixelSize: maxPixelSize)
            await report(page: page, success: true, bytes: result.byteCount, cached: result.wasCached, duration: start.duration(to: clock.now))
            return result.image
        } catch {
            await report(page: page, success: false, bytes: 0, cached: false, duration: start.duration(to: clock.now))
            throw error
        }
    }

    func cachedImage(for url: URL, maxPixelSize: Int) -> CGImage? {
        memory.image(forKey: Key(url: url, maxPixelSize: maxPixelSize).memoryKey)
    }

    /// Warms the cache without surfacing errors; safe to call speculatively.
    func prefetch(urls: [URL], maxPixelSize: Int) {
        for url in urls {
            let key = Key(url: url, maxPixelSize: maxPixelSize)
            guard memory.image(forKey: key.memoryKey) == nil, inFlight[key] == nil else { continue }
            let http = http
            let memory = memory
            let disk = disk
            let hostResolver = hostResolver
            let task = Task<ImageLoadResult, any Error> {
                try await Self.fetch(
                    url: url,
                    key: key,
                    http: http,
                    memory: memory,
                    disk: disk,
                    hostResolver: hostResolver
                )
            }
            inFlight[key] = task
            Task {
                _ = try? await task.value
                self.finish(key: key)
            }
        }
    }

    // MARK: - Maintenance

    func clearMemory() {
        memory.removeAll()
    }

    func clearDisk() {
        disk.removeAll()
    }

    func diskUsage() -> Int64 {
        disk.totalSize()
    }

    func cachedByteCount() -> Int64 {
        disk.totalSize()
    }

    // MARK: - Private

    private func finish(key: Key) {
        inFlight[key] = nil
    }

    private static func fetch(
        url: URL,
        key: Key,
        http: HTTPClient,
        memory: MemoryImageCache,
        disk: DiskImageCache,
        hostResolver: (any HostImageResolving)?
    ) async throws -> ImageLoadResult {
        if let data = disk.data(forKey: key.diskKey),
           let image = Downsampler.downsample(data, maxPixelSize: key.maxPixelSize) {
            memory.insert(image, forKey: key.memoryKey)
            return ImageLoadResult(image: image, byteCount: data.count, wasCached: true)
        }

        // Images owned by a provider host: only the host can fetch these, because
        // it carries the parser's headers, cookies and descrambling.
        if let (sourceKey, remote) = HostImageURL.parse(url) {
            guard let hostResolver else {
                throw MangaSourceError.provider("This image needs the parser host, which is unavailable.")
            }
            let localFile = try await hostResolver.localImageFile(sourceKey: sourceKey, remote: remote)
            guard let data = try? Data(contentsOf: localFile),
                  let image = Downsampler.downsample(data, maxPixelSize: key.maxPixelSize)
            else {
                throw MangaSourceError.decoding("Unsupported image data")
            }
            // Cached against the logical URL, so repeated reads stay a cache hit.
            disk.store(data, forKey: key.diskKey)
            memory.insert(image, forKey: key.memoryKey)
            return ImageLoadResult(image: image, byteCount: data.count, wasCached: false)
        }

        // Offline downloads are addressed as file URLs; read them directly.
        if url.isFileURL {
            guard let data = try? Data(contentsOf: url),
                  let image = Downsampler.downsample(data, maxPixelSize: key.maxPixelSize)
            else {
                throw MangaSourceError.notFound
            }
            memory.insert(image, forKey: key.memoryKey)
            return ImageLoadResult(image: image, byteCount: data.count, wasCached: false)
        }

        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        let response: HTTPResponse
        do {
            response = try await http.data(for: request)
        } catch let error as HTTPError {
            throw MangaSourceError.network(error.errorDescription ?? "Image download failed")
        }

        guard let image = Downsampler.downsample(response.data, maxPixelSize: key.maxPixelSize) else {
            throw MangaSourceError.decoding("Unsupported image data")
        }
        disk.store(response.data, forKey: key.diskKey)
        memory.insert(image, forKey: key.memoryKey)
        return ImageLoadResult(image: image, byteCount: response.data.count, wasCached: false)
    }

    private func report(page: Page, success: Bool, bytes: Int, cached: Bool, duration: Duration) async {
        guard let reportURL = page.healthReportURL else { return }
        let payload: [String: Any] = [
            "url": page.url.absoluteString,
            "success": success,
            "bytes": bytes,
            "duration": Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000),
            "cached": cached,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: reportURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Health reporting is best-effort: never surface failures to the reader.
        _ = try? await http.data(for: request, allowRetry: false)
    }
}
