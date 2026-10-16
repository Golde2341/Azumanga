import Foundation
import Testing
@testable import Uzumaki

@Suite("Reader spread paging")
struct ReaderSpreadsTests {
    private func pages(_ count: Int) -> [Page] {
        (0..<count).map { Page(index: $0, url: URL(string: "https://example.test/\($0).jpg")!) }
    }

    // MARK: - Grouping

    @Test("Single-page mode gives one page per spread")
    func singlePageGrouping() {
        let spreads = ReaderSpreads.group(pages(4), pageMode: .single, firstPageAlone: true)
        #expect(spreads.count == 4)
        #expect(spreads.map { $0.map(\.index) } == [[0], [1], [2], [3]])
    }

    @Test("Double-page mode pairs facing pages, leaving the first alone")
    func doublePageGrouping() {
        let spreads = ReaderSpreads.group(pages(6), pageMode: .double, firstPageAlone: true)
        // First page alone, then 1-2, 3-4, 5.
        #expect(spreads.map { $0.map(\.index) } == [[0], [1, 2], [3, 4], [5]])
    }

    @Test("Double-page mode pairs from the start when the first page is not alone")
    func doublePageWithoutLeadingSingle() {
        let spreads = ReaderSpreads.group(pages(5), pageMode: .double, firstPageAlone: false)
        #expect(spreads.map { $0.map(\.index) } == [[0, 1], [2, 3], [4]])
    }

    @Test("A single page is never paired")
    func singlePageInput() {
        let spreads = ReaderSpreads.group(pages(1), pageMode: .double, firstPageAlone: true)
        #expect(spreads.map { $0.map(\.index) } == [[0]])
    }

    // MARK: - Locating a spread

    @Test("The spread showing a page is found whether or not it starts it")
    func spreadShowingAPage() {
        let spreads = ReaderSpreads.group(pages(7), pageMode: .double, firstPageAlone: true)
        #expect(spreads.map { $0.map(\.index) } == [[0], [1, 2], [3, 4], [5, 6]])

        // A page that starts its spread, and one that shares it with a neighbour — the
        // case a restored reading position can land on.
        #expect(ReaderSpreads.spreadIndex(showing: 3, in: spreads) == 2)
        #expect(ReaderSpreads.spreadIndex(showing: 2, in: spreads) == 1)
        #expect(ReaderSpreads.spreadIndex(showing: 6, in: spreads) == 3)

        // Only the first page of a spread begins it.
        #expect(ReaderSpreads.spreadIndex(beginningWith: 3, in: spreads) == 2)
        #expect(ReaderSpreads.spreadIndex(beginningWith: 2, in: spreads) == nil)

        #expect(ReaderSpreads.spreadIndex(showing: 99, in: spreads) == nil)
        #expect(ReaderSpreads.spreadIndex(showing: 0, in: []) == nil)
        #expect(ReaderSpreads.spreadIndex(beginningWith: 0, in: []) == nil)
    }
}
