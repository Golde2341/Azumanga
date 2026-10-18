import Foundation
import SwiftUI

/// Backs the Browse section: popular/latest listings and search, against
/// whichever source the user selects.
@MainActor
@Observable
final class DiscoveryModel {
    enum Mode: String, CaseIterable, Identifiable {
        case popular
        case latest
        case search

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .popular: "Popular"
            case .latest: "Latest"
            case .search: "Search"
            }
        }
    }

    private let services: Services

    var mode: Mode = .popular
    var selectedSourceId: String?
    var searchText = ""
    var filters: [MangaFilterValue] = []
    var filterDescriptors: [MangaFilter] = []

    var results: [Manga] = []
    var availableSources: [SourceInfo] = []

    var isLoading = false
    var isLoadingMore = false
    var hasNextPage = false
    var errorMessage: String?

    private var currentPage = 0

    init(services: Services) {
        self.services = services
    }

    var sourcePicker: [SourceInfo] {
        availableSources
    }

    func refreshSources() async {
        let enabled = await services.registry.enabledInfos()
        let pinned = await services.registry.all().filter(\.isPinned)

        var byID: [String: SourceInfo] = [:]
        for source in enabled {
            byID[source.id] = source
        }
        for source in pinned {
            byID[source.id] = source
        }
        availableSources = byID.values.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        if selectedSourceId == nil || !availableSources.contains(where: { $0.id == selectedSourceId }) {
            selectedSourceId = availableSources.first?.id
        }
        await loadFilters()
    }

    func selectSource(_ id: String) async {
        guard id != selectedSourceId else { return }
        selectedSourceId = id
        filters = []
        await loadFilters()
        await loadFirstPage()
    }

    private func loadFilters() async {
        guard let source = await activeSource() else {
            filterDescriptors = []
            return
        }
        filterDescriptors = (try? await source.filters()) ?? []
        filters = filters.filter { value in
            filterDescriptors.contains { $0.id == value.filterId }
        }
    }

    // MARK: - Loading

    func loadFirstPage() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard let source = await activeSource() else {
            results = []
            hasNextPage = false
            errorMessage = availableSources.isEmpty ? "No sources are enabled." : nil
            return
        }
        selectedSourceId = source.id

        do {
            let page = try await fetch(source: source, page: 0)
            results = page.items
            hasNextPage = page.hasNextPage
            currentPage = 0
        } catch is CancellationError {
            // Superseded by a newer request.
        } catch {
            results = []
            hasNextPage = false
            errorMessage = userFacingMessage(for: error)
        }
    }

    func loadNextPage() async {
        guard !isLoading, !isLoadingMore, hasNextPage else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        guard let source = await activeSource() else { return }
        do {
            let page = try await fetch(source: source, page: currentPage + 1)
            let existing = Set(results.map(\.id))
            let fresh = page.items.filter { !existing.contains($0.id) }
            results.append(contentsOf: fresh)

            // Some sources return a fixed page regardless of offset, and Kotatsu's
            // host has no reliable end-of-list signal. Treating a page that adds
            // nothing new as the end stops an endless scroll that shows nothing.
            hasNextPage = page.hasNextPage && !fresh.isEmpty
            currentPage += 1
        } catch is CancellationError {
            // Superseded.
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func search(query: String) async {
        searchText = query
        mode = .search
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mode = .popular
        }
        await loadFirstPage()
    }

    func setFilter(id: String, value: MangaFilterValue.Kind) async {
        filters.removeAll { $0.filterId == id }
        filters.append(MangaFilterValue(filterId: id, kind: value))
        await loadFirstPage()
    }

    func clearFilters() async {
        filters = []
        await loadFirstPage()
    }

    // MARK: - Private

    private func fetch(source: any MangaSource, page: Int) async throws -> PagedResult<Manga> {
        switch mode {
        case .popular:
            if source.supports(.popular) {
                return try await source.popular(page: page)
            }
            return try await source.search("", page: page, filters: filters)
        case .latest:
            if source.supports(.latest) {
                return try await source.latest(page: page)
            }
            return try await source.search("", page: page, filters: filters)
        case .search:
            return try await source.search(searchText, page: page, filters: filters)
        }
    }

    private func activeSource() async -> (any MangaSource)? {
        if let selectedSourceId, let source = await services.registry.source(id: selectedSourceId) {
            return source
        }
        return await services.registry.enabledSources().first
    }
}
