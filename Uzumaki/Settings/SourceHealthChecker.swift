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
