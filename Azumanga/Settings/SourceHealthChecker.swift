import Foundation
import SwiftUI

/// Checks every source by asking it for a first page, records the outcome, and
/// switches off the ones that fail.
///
/// Runs one source at a time on purpose: the parser host handles requests serially,
/// and hammering it concurrently would not be faster — it would just interleave
/// timeouts. Each probe carries a short deadline so a dead site cannot stall the run.
@MainActor
@Observable
final class SourceHealthChecker {
    private let services: Services
    private var task: Task<Void, Never>?

    var isRunning = false
    var completed = 0
    var total = 0
    var currentSourceName: String?
    var workingCount = 0
    var failingCount = 0
    var lastRunSummary: String?

    /// Called after each source so the UI can update live during a long run.
    /// Arguments: source id, its health snapshot, and whether it is now enabled.
    var onResult: (@MainActor (String, SourceHealthSnapshot, Bool) -> Void)?

    init(services: Services) {
        self.services = services
    }

    var progress: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    // MARK: - Running

    /// - Parameter onlyUntested: when true, sources already known to work are
    ///   skipped, so repeat runs get faster.
    func start(sources: [SourceInfo], onlyUntested: Bool = false) {
        guard !isRunning else { return }

        let queue = onlyUntested
            ? sources.filter { services.health(for: $0.id).health != .working }
            : sources
        guard !queue.isEmpty else {
            lastRunSummary = "Nothing to check."
            return
        }

        isRunning = true
        completed = 0
        workingCount = 0
        failingCount = 0
        total = queue.count
        lastRunSummary = nil

        task = Task { [weak self] in
            guard let self else { return }

            let handledInBatch = await self.checkKotatsuBatch(queue)
            if !handledInBatch {
                for info in queue {
                    if Task.isCancelled { break }
                    self.currentSourceName = info.name

                    let outcome = await self.check(info)
                    switch outcome.health {
                    case .working: self.workingCount += 1
                    case .failing: self.failingCount += 1
                    case .untested: break
                    }
                    self.apply(outcome, to: info)
                    self.completed += 1
                }
            }

            self.currentSourceName = nil
            self.isRunning = false
            self.lastRunSummary = Task.isCancelled
                ? "Stopped after \(self.completed) of \(self.total)."
                : "\(self.workingCount) working, \(self.failingCount) not working."
            self.task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - Private

    private struct Outcome {
        var health: SourceHealth
        var detail: String?
    }

    /// Checks Kotatsu sources in one host call, which runs the probes concurrently.
    /// Returns false when the batch path is unavailable, so the caller can fall
    /// back to the ordinary sequential checker.
    private func checkKotatsuBatch(_ sources: [SourceInfo]) async -> Bool {
        guard let host = services.kotatsuHost,
              !sources.isEmpty,
              sources.allSatisfy({ $0.provider == .kotatsuHost })
        else { return false }

        let prefix = "kotatsu."
        let keys = sources.map {
            String($0.id.dropFirst(prefix.count))
        }
        let perSourceTimeoutMilliseconds = 8_000
        let rounds = max(1, Int(ceil(Double(keys.count) / 24.0)))
        let hostTimeout = Duration.seconds(rounds * 9 + 10)

        currentSourceName = "Checking \(sources.count) selected sources…"

        do {
            let response = try await host.call(
                "health",
                parameters: KotatsuHealthRequest(
                    sources: keys,
                    timeoutMs: perSourceTimeoutMilliseconds
                ),
                as: KotatsuHealthResponse.self,
                timeout: hostTimeout
            )
            guard !Task.isCancelled else { return true }

            let results = Dictionary(
                response.items.map { ($0.key, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            for info in sources {
                let key = String(info.id.dropFirst(prefix.count))
                let outcome: Outcome
                if let result = results[key] {
                    outcome = Outcome(
                        health: result.ok ? .working : .failing,
                        detail: result.detail
                    )
                } else {
                    outcome = Outcome(
                        health: .failing,
                        detail: "The parser host did not return a result."
                    )
                }

                switch outcome.health {
                case .working: workingCount += 1
                case .failing: failingCount += 1
                case .untested: break
                }
                apply(outcome, to: info)
                completed += 1
            }

            return true
        } catch {
            // An older host without the batch endpoint falls back to sequential
            // probing rather than marking every source as failed.
            return Task.isCancelled
        }
    }

    private func check(_ info: SourceInfo) async -> Outcome {
        guard let source = await services.registry.source(id: info.id) else {
            return Outcome(health: .failing, detail: "The source is no longer registered.")
        }

        do {
            let count: Int
            if let probing = source as? any SourceProbing {
                count = try await probing.probe()
            } else {
                count = try await source.popular(page: 0).items.count
            }
            guard count > 0 else {
                return Outcome(health: .failing, detail: "The source returned no results.")
            }
            return Outcome(health: .working, detail: "\(count) results")
        } catch is CancellationError {
            return Outcome(health: .untested, detail: nil)
        } catch {
            return Outcome(health: .failing, detail: userFacingMessage(for: error))
        }
    }

    private func apply(_ outcome: Outcome, to info: SourceInfo) {
        guard outcome.health != .untested else { return }

        let working = outcome.health == .working
        // A source that does not answer should not sit enabled in the picker.
        try? services.sourceStore.recordHealth(
            outcome.health,
            detail: outcome.detail,
            sourceId: info.id,
            disableOnFailure: true
        )
        if working {
            try? services.sourceStore.setEnabled(true, sourceId: info.id)
        }
        Task { await services.registry.setEnabled(working, id: info.id) }

        onResult?(
            info.id,
            SourceHealthSnapshot(health: outcome.health, detail: outcome.detail, checkedAt: Date()),
            working
        )
    }
}
