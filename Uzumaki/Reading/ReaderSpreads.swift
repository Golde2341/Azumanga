import Foundation

/// Paging maths for the horizontal reader.
///
/// The scroll view itself is the platform's paged one, but a turn has to be counted
/// in *spread* space rather than page space: in double-page mode consecutive pages
/// share a spread, so stepping by one page would land inside the spread already
/// showing.
nonisolated enum ReaderSpreads {
    /// Groups pages into what is shown at once: one page each, or facing pairs.
    static func group(_ pages: [Page], pageMode: PageMode, firstPageAlone: Bool) -> [[Page]] {
        guard pageMode == .double, pages.count > 1 else {
            return pages.map { [$0] }
        }

        var result: [[Page]] = []
        var index = 0
        // With the first page alone, the following pages pair up the way printed
        // manga does: page 2 faces page 3, not page 1.
        if firstPageAlone {
            result.append([pages[0]])
            index = 1
        }
        while index < pages.count {
            let end = min(index + 2, pages.count)
            result.append(Array(pages[index..<end]))
            index = end
        }
        return result
    }

    /// Index of the spread that begins with the given page.
    static func spreadIndex(beginningWith pageIndex: Int, in spreads: [[Page]]) -> Int? {
        spreads.firstIndex { $0.first?.index == pageIndex }
    }

    /// Index of the spread showing the given page, whether it starts that spread or
    /// shares it with a neighbour.
    ///
    /// Restoring a saved position can land on a page that no spread begins with, and
    /// asking for the spread "beginning with" it would come up empty.
    static func spreadIndex(showing pageIndex: Int, in spreads: [[Page]]) -> Int? {
        if let exact = spreadIndex(beginningWith: pageIndex, in: spreads) {
            return exact
        }
        return spreads.firstIndex { spread in
            spread.contains { $0.index == pageIndex }
        }
    }
}
