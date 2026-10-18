import Foundation
import SwiftUI

/// Drives the download queue on behalf of the UI: creates records, runs jobs
/// through `DownloadManager`, and tracks live progress.
@MainActor
@Observable
final class DownloadsModel {
    private let services: Services
    private var tasks: [String: Task<Void, Never>] = [:]

    var records: [DownloadRecord] = []
    var progress: [String: DownloadProgress] = [:]
    var errorMessage: String?
    var totalBytes: Int64 = 0

    init(services: Services) {
        self.services = services
        reconcileStaleRecords()
        reload()
    }

    // MARK: - Queries

    var activeRecords: [DownloadRecord] {
        records.filter { $0.state == .downloading || $0.state == .queued }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var completedRecords: [DownloadRecord] {
        records.filter { $0.state == .completed }
    }

    var failedOrPausedRecords: [DownloadRecord] {
        records.filter { $0.state == .failed || $0.state == .paused }
    }

    func state(of chapter: Chapter) -> DownloadState? {
        records.first { $0.key == "\(chapter.sourceId):\(chapter.mangaId):\(chapter.chapterId)" }?.state
    }

    func record(for chapter: Chapter) -> DownloadRecord? {
        records.first { $0.key == "\(chapter.sourceId):\(chapter.mangaId):\(chapter.chapterId)" }
    }

    func job(for chapter: Chapter, manga: Manga) -> DownloadJob {
        DownloadJob(
            sourceId: chapter.sourceId,
            mangaId: chapter.mangaId,
            mangaTitle: manga.title,
            chapterId: chapter.chapterId,
            chapterTitle: chapter.title,
            chapterNumber: chapter.number
        )
    }

    func progress(for record: DownloadRecord) -> DownloadProgress? {
        progress[record.key]
    }

    func reload() {
        do {
            records = try services.downloadStore.all()
            totalBytes = try services.downloadStore.totalByteCount()
            errorMessage = nil
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    // MARK: - Queue

    func enqueue(_ job: DownloadJob) {
        let key = Self.key(job)
        guard tasks[key] == nil else { return }
        guard state(forKey: key) != .completed else { return }

        do {
            let record = try existingRecord(for: job) ?? {
                let new = DownloadRecord(
                    sourceId: job.sourceId,
                    mangaId: job.mangaId,
                    mangaTitle: job.mangaTitle,
                    chapterId: job.chapterId,
                    chapterTitle: job.chapterTitle,
                    chapterNumber: job.chapterNumber,
                    state: .queued,
                    directoryName: "\(job.sourceId)/\(job.mangaId)/\(job.chapterId)"
                )
                return try services.downloadStore.upsert(new)
            }()
            record.state = .queued
            record.errorMessage = nil
            try services.downloadStore.upsert(record)
            reload()
            start(job)
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func enqueue(chapters: [Chapter], manga: Manga) {
        for chapter in chapters where chapter.externalURL == nil {
            enqueue(
                DownloadJob(
                    sourceId: manga.sourceId,
                    mangaId: manga.mangaId,
                    mangaTitle: manga.title,
                    chapterId: chapter.chapterId,
                    chapterTitle: chapter.title,
                    chapterNumber: chapter.number
                )
            )
        }
    }

    func pause(_ record: DownloadRecord) {
        tasks[record.key]?.cancel()
        tasks[record.key] = nil
        setState(.paused, for: record)
        progress[record.key] = nil
        reload()
    }

    func resume(_ record: DownloadRecord) {
        guard tasks[record.key] == nil else { return }
        let job = job(for: record)
        setState(.queued, for: record)
        start(job)
    }

    func retry(_ record: DownloadRecord) {
        resume(record)
    }

    func cancel(_ record: DownloadRecord) {
        tasks[record.key]?.cancel()
        tasks[record.key] = nil
        delete(record)
    }

    func delete(_ record: DownloadRecord) {
        let job = job(for: record)
        tasks[record.key]?.cancel()
        tasks[record.key] = nil
        progress[record.key] = nil
        Task {
            await services.downloads.deleteFiles(job)
            try? services.downloadStore.delete(record)
            reload()
        }
    }

    func deleteAll() {
        for record in records {
            tasks[record.key]?.cancel()
            let job = job(for: record)
            Task { await services.downloads.deleteFiles(job) }
            try? services.downloadStore.delete(record)
        }
        tasks.removeAll()
        progress.removeAll()
        reload()
    }

    // MARK: - Private

    private func start(_ job: DownloadJob) {
        let key = Self.key(job)
        let services = self.services

        tasks[key] = Task { [weak self] in
            self?.setState(.downloading, forKey: key)
            do {
                let outcome = try await services.downloads.run(job) { [weak self] update in
                    // Delivered on the main actor, preserving ordering.
                    self?.progress[key] = update
                    self?.persistProgress(key: key, update: update)
                }
                try? services.downloadStore.update(
                    sourceId: job.sourceId,
                    mangaId: job.mangaId,
                    chapterId: job.chapterId,
                    state: .completed,
                    downloadedPages: outcome.pageCount,
                    totalPages: outcome.pageCount,
                    byteCount: outcome.byteCount,
                    errorMessage: .some(nil)
                )
            } catch is CancellationError {
                // Paused or cancelled; the caller already set the intended state.
            } catch {
                try? services.downloadStore.update(
                    sourceId: job.sourceId,
                    mangaId: job.mangaId,
                    chapterId: job.chapterId,
                    state: .failed,
                    errorMessage: .some(userFacingMessage(for: error))
                )
                self?.errorMessage = userFacingMessage(for: error)
            }

            self?.tasks[key] = nil
            self?.progress[key] = nil
            self?.reload()
        }
    }

    private func persistProgress(key: String, update: DownloadProgress) {
        guard let record = records.first(where: { $0.key == key }) else { return }
        try? services.downloadStore.update(
            sourceId: record.sourceId,
            mangaId: record.mangaId,
            chapterId: record.chapterId,
            state: .downloading,
            downloadedPages: update.completedPages,
            totalPages: update.totalPages,
            byteCount: update.byteCount
        )
    }

    private func setState(_ state: DownloadState, for record: DownloadRecord) {
        try? services.downloadStore.update(
            sourceId: record.sourceId,
            mangaId: record.mangaId,
            chapterId: record.chapterId,
            state: state
        )
    }

    private func setState(_ state: DownloadState, forKey key: String) {
        guard let record = records.first(where: { $0.key == key }) else { return }
        setState(state, for: record)
    }

    private func state(forKey key: String) -> DownloadState? {
        records.first { $0.key == key }?.state
    }

    private func existingRecord(for job: DownloadJob) throws -> DownloadRecord? {
        try services.downloadStore.record(sourceId: job.sourceId, mangaId: job.mangaId, chapterId: job.chapterId)
    }

    private func job(for record: DownloadRecord) -> DownloadJob {
        DownloadJob(
            sourceId: record.sourceId,
            mangaId: record.mangaId,
            mangaTitle: record.mangaTitle,
            chapterId: record.chapterId,
            chapterTitle: record.chapterTitle,
            chapterNumber: record.chapterNumber
        )
    }

    /// A download that was interrupted by a quit shows as paused rather than
    /// pretending to still be running.
    private func reconcileStaleRecords() {
        for record in (try? services.downloadStore.all()) ?? [] where record.state == .downloading || record.state == .queued {
            setState(.paused, for: record)
        }
    }

    private static func key(_ job: DownloadJob) -> String {
        "\(job.sourceId):\(job.mangaId):\(job.chapterId)"
    }
}
