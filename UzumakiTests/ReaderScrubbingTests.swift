import Foundation
import Testing
@testable import Uzumaki

@Suite("Reader progress bar")
struct ReaderScrubbingTests {
    @Test("The ends of the bar are the first and last pages")
    func endsOfTheBar() {
        #expect(ReaderScrubbing.page(atFraction: 0, pageCount: 10) == 0)
        #expect(ReaderScrubbing.page(atFraction: 1, pageCount: 10) == 9)

        #expect(ReaderScrubbing.fraction(ofPage: 0, pageCount: 10) == 0)
        #expect(ReaderScrubbing.fraction(ofPage: 9, pageCount: 10) == 1)
    }

    @Test("A bar position maps to the page it is nearest")
    func positionsMapToPages() {
        // Ten pages: nine gaps, so each gap is a ninth of the bar.
        #expect(ReaderScrubbing.page(atFraction: 0.1, pageCount: 10) == 1)
        #expect(ReaderScrubbing.page(atFraction: 0.5, pageCount: 10) == 5)
        #expect(ReaderScrubbing.page(atFraction: 0.99, pageCount: 10) == 9)
    }

    @Test("A position and the page it gives map back to each other")
    func roundTrip() {
        for pageCount in [2, 5, 10, 137] {
            for page in 0..<pageCount {
                let fraction = ReaderScrubbing.fraction(ofPage: page, pageCount: pageCount)
                #expect(ReaderScrubbing.page(atFraction: fraction, pageCount: pageCount) == page)
            }
        }
    }

    @Test("A position off either end is held at the ends")
    func clampesBeyondTheBar() {
        #expect(ReaderScrubbing.page(atFraction: -3, pageCount: 10) == 0)
        #expect(ReaderScrubbing.page(atFraction: 4, pageCount: 10) == 9)
        #expect(ReaderScrubbing.fraction(ofPage: -4, pageCount: 10) == 0)
        #expect(ReaderScrubbing.fraction(ofPage: 99, pageCount: 10) == 1)
    }

    @Test("A chapter of one page, or none, sits at the start")
    func degeneratePageCounts() {
        #expect(ReaderScrubbing.page(atFraction: 0.5, pageCount: 1) == 0)
        #expect(ReaderScrubbing.page(atFraction: 0.5, pageCount: 0) == 0)
        #expect(ReaderScrubbing.fraction(ofPage: 0, pageCount: 1) == 0)
        #expect(ReaderScrubbing.fraction(ofPage: 0, pageCount: 0) == 0)
    }
}

@Suite("Reading presets")
struct ReaderPresetTests {
    @Test("Webtoon is a vertical scroll")
    func webtoon() {
        #expect(ReaderPreset.webtoon.layout == .vertical)
        #expect(ReaderPreset.webtoon.pageMode == .single)
    }

    @Test("Classic is double-paged and horizontal")
    func classic() {
        #expect(ReaderPreset.classic.layout == .horizontal)
        #expect(ReaderPreset.classic.pageMode == .double)
    }
}
