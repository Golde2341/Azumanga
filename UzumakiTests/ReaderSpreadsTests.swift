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

    // MARK: - Stepping

    @Test("A turn moves exactly one spread")
    func turnsOneSpread() {
        #expect(ReaderSpreads.step(from: 3, by: 1, count: 10) == 4)
        #expect(ReaderSpreads.step(from: 3, by: -1, count: 10) == 2)
    }

    @Test("Turns stop at the ends")
    func turnsStopAtEnds() {
        #expect(ReaderSpreads.step(from: 0, by: -1, count: 4) == 0)
        #expect(ReaderSpreads.step(from: 3, by: 1, count: 4) == 3)
        #expect(ReaderSpreads.step(from: 0, by: 0, count: 4) == 0)
        #expect(ReaderSpreads.step(from: 0, by: 1, count: 0) == 0)
    }

    @Test("Stepping works in spread space, where indices are not contiguous")
    func stepsInSpreadSpace() {
        // Double-page: spreads begin at pages 0, 1, 3, 5.
        let spreads = ReaderSpreads.group(pages(7), pageMode: .double, firstPageAlone: true)
        #expect(spreads.map { $0.first?.index } == [0, 1, 3, 5])

        // A turn from the spread starting at page 1 lands on the one starting at 3,
        // not on page 2, which shares its spread.
        let current = ReaderSpreads.spreadIndex(beginningWith: 1, in: spreads)
        #expect(current == 1)
        let next = ReaderSpreads.step(from: current ?? 0, by: 1, count: spreads.count)
        #expect(next == 2)
        #expect(spreads[next].first?.index == 3)

        // A page that shares a spread has no spread of its own.
        #expect(ReaderSpreads.spreadIndex(beginningWith: 2, in: spreads) == nil)
    }

    @Test("The spread showing a page is found whether or not it starts it")
    func spreadShowingAPage() {
        let spreads = ReaderSpreads.group(pages(7), pageMode: .double, firstPageAlone: true)
        #expect(spreads.map { $0.map(\.index) } == [[0], [1, 2], [3, 4], [5, 6]])

        // A page that starts its spread.
        #expect(ReaderSpreads.spreadIndex(showing: 3, in: spreads) == 2)
        // A page that shares it — the case a restored position can land on.
        #expect(ReaderSpreads.spreadIndex(showing: 2, in: spreads) == 1)
        #expect(ReaderSpreads.spreadIndex(showing: 6, in: spreads) == 3)

        // Nothing at all for a page that is not there.
        #expect(ReaderSpreads.spreadIndex(showing: 99, in: spreads) == nil)
        #expect(ReaderSpreads.spreadIndex(showing: 0, in: []) == nil)
    }
}
