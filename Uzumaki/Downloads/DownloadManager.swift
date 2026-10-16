import Foundation

/// Downloads chapters for offline reading. Bounded concurrency, resumable (pages
/// already on disk are skipped), and cancellable between pages.
actor DownloadManager {
    private let registry: SourceRegistry
    private let http: HTTPClient
    private let directories: DownloadDirectories
    private let maxConcurrentJobs: Int

    private var runningJobs = 0
    private var waitingSlots: [CheckedContinuation<Void, Never>] = []

    init(
        registry: SourceRegistry,
        http: HTTPClient,
        directories: DownloadDirectories = DownloadDirectories(),
        maxConcurrentJobs: Int = 2
    ) {
        self.registry = registry
        self.http = http
        self.directories = directories
        self.maxConcurrentJobs = max(1, maxConcurrentJobs)
    }

    // MARK: - Downloading

    /// Downloads every page of a chapter. Safe to call again after a failure:
    /// pages already written are reused.
    func run(
        _ job: DownloadJob,
        onProgress: @escaping @MainActor @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadOutcome {
        await acquireSlot()
        defer { releaseSlot() }

        guard let source = await registry.source(id: job.sourceId) else {
            throw MangaSourceError.provider("The source for this chapter is no longer available.")
        }

        let remote = try await source.pages(chapterId: job.chapterId)
        guard !remote.isEmpty else {
            throw MangaSourceError.notFound
        }

        let directory = directories.chapterDirectory(
            sourceId: job.sourceId,
            mangaId: job.mangaId,
            chapterId: job.chapterId
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let existing = Set(directories.pageFiles(in: directory).map(\.index))
        var completed = existing.count
        var bytes = directories.byteCount(in: directory)

        await onProgress(DownloadProgress(completedPages: completed, totalPages: remote.count, byteCount: bytes))

        for page in remote {
            try Task.checkCancellation()

            if existing.contains(page.index) {
                continue
            }

            var request = URLRequest(url: page.url)
            for (key, value) in page.headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            request.setValue("image/*", forHTTPHeaderField: "Accept")

            let response = try await http.data(for: request, allowRetry: true)
            let file = directories.pageFile(in: directory, index: page.index, sourceURL: page.url)
            try response.data.write(to: file, options: .atomic)

            bytes += Int64(response.data.count)
            completed += 1
            await onProgress(DownloadProgress(completedPages: completed, totalPages: remote.count, byteCount: bytes))
        }

        return DownloadOutcome(pageCount: remote.count, byteCount: directories.byteCount(in: directory))
    }

    // MARK: - Offline access

    /// Pages already on disk for a chapter, ordered by index. Empty when nothing
    /// has been downloaded.
    func localPages(_ job: DownloadJob) -> [Page] {
        let directory = directories.chapterDirectory(
            sourceId: job.sourceId,
            mangaId: job.mangaId,
            chapterId: job.chapterId
        )
        return directories.pageFiles(in: directory).map { file in
            Page(index: file.index, url: file.url)
        }
    }

    func byteCount(_ job: DownloadJob) -> Int64 {
        directories.byteCount(in: directories.chapterDirectory(
            sourceId: job.sourceId,
            mangaId: job.mangaId,
            chapterId: job.chapterId
        ))
    }

    func deleteFiles(_ job: DownloadJob) {
        directories.removeChapter(sourceId: job.sourceId, mangaId: job.mangaId, chapterId: job.chapterId)
    }

    func totalSize() -> Int64 {
        directories.totalSize()
    }

    // MARK: - Concurrency gate

    private func acquireSlot() async {
        if runningJobs < maxConcurrentJobs {
            runningJobs += 1
            return
        }
        await withCheckedContinuation { continuation in
            waitingSlots.append(continuation)
        }
        runningJobs += 1
    }

    private func releaseSlot() {
        runningJobs = max(0, runningJobs - 1)
        guard !waitingSlots.isEmpty else { return }
        let next = waitingSlots.removeFirst()
        next.resume()
    }
}
