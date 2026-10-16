import Foundation

/// One page of results from a paginated source request.
nonisolated struct PagedResult<Element: Sendable>: Sendable {
    var items: [Element]
    var hasNextPage: Bool
    var totalCount: Int?

    init(items: [Element], hasNextPage: Bool, totalCount: Int? = nil) {
        self.items = items
        self.hasNextPage = hasNextPage
        self.totalCount = totalCount
    }
}

extension PagedResult {
    static var empty: PagedResult<Element> {
        PagedResult(items: [], hasNextPage: false, totalCount: nil)
    }

    func map<T: Sendable>(_ transform: (Element) -> T) -> PagedResult<T> {
        PagedResult<T>(items: items.map(transform), hasNextPage: hasNextPage, totalCount: totalCount)
    }
}
