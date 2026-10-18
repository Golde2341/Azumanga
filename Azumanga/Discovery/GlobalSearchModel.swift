import Foundation
import Observation

/// Searches every enabled source plus pinned sources. Results are grouped by
/// source so the source name and its cover row read as one result.
@MainActor
@Observable
final class GlobalSearchModel {
    struct SourceRow: Identifiable {
        var source: SourceInfo
        var results: [Manga]
        var error: String?

        var id: String { source.id }
    }

    private struct Outcome: Sendable {
        let results: [Manga]
        let error: String?
    }

    private struct SourceOutcome: Sendable {
        let source: SourceInfo
        let outcome: Outcome
    }

    private let services: Services
    private let defaults: UserDefaults
    private static let recentSourceKey = "globalSearch.mostRecentSourceID"
    private var activeSearchID = 0
    private var searchSources: [SourceInfo] = []

    private(set) var rows: [SourceRow] = []
    private(set) var isSearching = false
    private(set) var hasSearched = false
    var errorMessage: String?

    init(services: Services, defaults: UserDefaults = .standard) {
        self.services = services
        self.defaults = defaults
    }

    var recentSourceID: String? {
        defaults.string(forKey: Self.recentSourceKey)
    }

    func clear() {
        activeSearchID &+= 1
        searchSources = []
        rows = []
        isSearching = false
        hasSearched = false
        errorMessage = nil
    }

    func search(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clear()
            return
        }

        activeSearchID &+= 1
        let generation = activeSearchID
        isSearching = true
        hasSearched = true
        rows = []
        errorMessage = nil

        let allSources = await services.registry.all()
        let candidates = allSources.filter { $0.isEnabled || $0.isPinned }
        guard !candidates.isEmpty else {
            searchSources = []
            rows = []
            errorMessage = "No sources are enabled or pinned."
            isSearching = false
            return
        }
        searchSources = candidates

        let host = services.kotatsuHost
        let kotatsuSources = candidates.filter { $0.provider == .kotatsuHost }
        let otherSources = candidates.filter { $0.provider != .kotatsuHost }

        var outcomes: [String: Outcome] = [:]
        var kotatsuActors: [String: KotatsuSource] = [:]
        var searchableKotatsu: [SourceInfo] = []

        for source in kotatsuSources {
            if let actor = await services.registry.source(id: source.id) as? KotatsuSource {
                kotatsuActors[source.id] = actor
                searchableKotatsu.append(source)
            } else {
                outcomes[source.id] = Outcome(
                    results: [],
                    error: "The source is no longer registered."
                )
            }
        }

        if host == nil {
            for source in searchableKotatsu {
                outcomes[source.id] = Outcome(
                    results: [],
                    error: "The parser host is not available."
                )
            }
            searchableKotatsu = []
        }

        var otherSourcesToSearch: [(SourceInfo, any MangaSource)] = []
        for source in otherSources {
            if let instance = await services.registry.source(id: source.id) {
                otherSourcesToSearch.append((source, instance))
            } else {
                outcomes[source.id] = Outcome(
                    results: [],
                    error: "The source is no longer registered."
                )
            }
        }

        // Pinned errors are useful immediately; ordinary working rows are added
        // as each source completes.
        rows = makeRows(candidates: searchSources, outcomes: outcomes)

        await withTaskGroup(of: [SourceOutcome].self) { group in
            if let host {
                let chunkSize = 12
                for start in stride(
                    from: 0,
                    to: searchableKotatsu.count,
                    by: chunkSize
                ) {
                    let chunk = Array(
                        searchableKotatsu[start..<min(start + chunkSize, searchableKotatsu.count)]
                    )
                    var actors: [String: KotatsuSource] = [:]
                    for source in chunk {
                        actors[source.id] = kotatsuActors[source.id]
                    }
                    group.addTask {
                        await Self.searchKotatsuChunk(
                            host: host,
                            sources: chunk,
                            actors: actors,
                            query: trimmed
                        )
                    }
                }
            }

            for (source, instance) in otherSourcesToSearch {
                group.addTask {
                    do {
                        let page = try await instance.search(
                            trimmed,
                            page: 0,
                            filters: []
                        )
                        return [
                            SourceOutcome(
                                source: source,
                                outcome: Outcome(results: page.items, error: nil)
                            )
                        ]
                    } catch {
                        return [
                            SourceOutcome(
                                source: source,
                                outcome: Outcome(
                                    results: [],
                                    error: userFacingMessage(for: error)
                                )
                            )
                        ]
                    }
                }
            }

            for await batch in group {
                guard generation == activeSearchID, !Task.isCancelled else {
                    return
                }
                for item in batch {
                    outcomes[item.source.id] = item.outcome
                    rows = makeRows(candidates: searchSources, outcomes: outcomes)
                }
            }
        }

        guard generation == activeSearchID else { return }
        isSearching = false
    }

    /// Persists the source the user just opened a manga from, so the next search
    /// presents that source first.
    func noteOpened(sourceID: String) {
        defaults.set(sourceID, forKey: Self.recentSourceKey)
        rows = sortedRows(rows)
    }

    func togglePin(sourceID: String) async {
        guard let index = rows.firstIndex(where: { $0.id == sourceID }) else {
            return
        }

        var row = rows[index]
        let isPinned = !row.source.isPinned
        await services.registry.setPinned(isPinned, id: sourceID)
        try? services.sourceStore.setPinned(isPinned, sourceId: sourceID)
        row.source.isPinned = isPinned
        rows[index] = row
        if let candidateIndex = searchSources.firstIndex(where: { $0.id == sourceID }) {
            searchSources[candidateIndex].isPinned = isPinned
        }
        rows = sortedRows(rows)
    }

    // MARK: - Kotatsu batch search

    private static func searchKotatsuChunk(
        host: KotatsuHostProcess,
        sources: [SourceInfo],
        actors: [String: KotatsuSource],
        query: String
    ) async -> [SourceOutcome] {
        let prefix = "kotatsu."
        let keys = sources.map { String($0.id.dropFirst(prefix.count)) }
        let rounds = max(1, Int(ceil(Double(keys.count) / 16.0)))
        let hostTimeout = Duration.seconds(rounds * 9 + 10)

        do {
            let response = try await host.call(
                "search",
                parameters: KotatsuSearchRequest(
                    sources: keys,
                    query: query,
                    timeoutMs: 8_000
                ),
                as: KotatsuSearchResponse.self,
                timeout: hostTimeout
            )

            let byKey = Dictionary(
                response.items.map { ($0.key, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            var results: [SourceOutcome] = []
            for source in sources {
                let key = String(source.id.dropFirst(prefix.count))
                guard let item = byKey[key] else {
                    results.append(SourceOutcome(
                        source: source,
                        outcome: Outcome(
                            results: [],
                            error: "The parser host did not return a result."
                        )
                    ))
                    continue
                }

                guard item.ok, let dtos = item.items else {
                    results.append(SourceOutcome(
                        source: source,
                        outcome: Outcome(
                            results: [],
                            error: item.detail ?? "The source could not be searched."
                        )
                    ))
                    continue
                }

                if let actor = actors[source.id] {
                    await actor.ingestSearchResults(dtos)
                }

                results.append(SourceOutcome(
                    source: source,
                    outcome: Outcome(
                        results: dtos.map {
                            KotatsuMapper.manga(
                                $0,
                                sourceId: source.id,
                                sourceKey: key
                            )
                        },
                        error: nil
                    )
                ))
            }
            return results
        } catch {
            let message = userFacingMessage(for: error)
            return sources.map {
                SourceOutcome(
                    source: $0,
                    outcome: Outcome(results: [], error: message)
                )
            }
        }
    }

    // MARK: - Row construction

    private func makeRows(
        candidates: [SourceInfo],
        outcomes: [String: Outcome]
    ) -> [SourceRow] {
        sortedRows(candidates.compactMap { source in
            guard let outcome = outcomes[source.id] else { return nil }

            if let error = outcome.error {
                // A failing enabled source is noise. A pinned one stays visible so
                // the user can see why it is not returning results.
                guard source.isPinned else { return nil }
                return SourceRow(source: source, results: [], error: error)
            }

            if outcome.results.isEmpty, !source.isPinned {
                return nil
            }

            return SourceRow(
                source: source,
                results: outcome.results,
                error: nil
            )
        })
    }

    // MARK: - Ordering

    private func sortedRows(_ rows: [SourceRow]) -> [SourceRow] {
        let recent = recentSourceID
        return rows.sorted { lhs, rhs in
            let leftRecent = lhs.source.id == recent
            let rightRecent = rhs.source.id == recent
            if leftRecent != rightRecent { return leftRecent }

            if lhs.source.isPinned != rhs.source.isPinned {
                return lhs.source.isPinned
            }

            return lhs.source.name.localizedStandardCompare(rhs.source.name)
                == .orderedAscending
        }
    }
}
