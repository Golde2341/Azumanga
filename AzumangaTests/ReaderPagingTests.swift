import Foundation
import Testing
@testable import Azumanga

@Suite("Reader scroll settling")
struct ReaderPagingTests {
    private let width: CGFloat = 800

    private let flick = ReaderPaging.fullSpeedVelocity * 2

    /// A slow drag: the fingers moved the page and stopped.
    private func dragged(from origin: CGFloat = 0, to position: CGFloat) -> CGFloat {
        settle(origin: origin, position: position, velocity: 0)
    }

    /// A flick: a quick gesture, which is its own decision regardless of distance.
    private func flicked(from origin: CGFloat = 0, to position: CGFloat) -> CGFloat {
        settle(origin: origin, position: position, velocity: flick)
    }

    private func settle(origin: CGFloat, position: CGFloat, velocity: CGFloat) -> CGFloat {
        ReaderPaging.settleTarget(
            origin: origin,
            position: position,
            pageWidth: width,
            velocity: velocity
        )
    }

    @Test("A drag that stops short of half a page springs back")
    func shortDragSpringsBack() {
        for position in [0, 40, width * 0.2, width * 0.49, -width * 0.3] as [CGFloat] {
            #expect(dragged(to: position) == 0)
        }
    }

    @Test("A drag past half a page turns")
    func dragPastHalfTurns() {
        #expect(dragged(to: width * 0.5) == width)
        #expect(dragged(to: width * 0.9) == width)
        #expect(dragged(to: -width * 0.6) == -width)
    }

    @Test("A long swipe crosses as many pages as it covers")
    func longSwipeCrossesManyPages() {
        // The whole point of following the fingers: no cap at one page per gesture.
        #expect(dragged(to: width * 2.4) == width * 2)
        #expect(dragged(to: width * 5.6) == width * 6)
        #expect(dragged(to: -width * 3.7) == -width * 4)
    }

    @Test("A flick turns the page without having to cross half of it")
    func flickTurnsFromShortOfHalf() {
        #expect(flicked(to: width * 0.05) == width)
        #expect(flicked(to: -width * 0.05) == -width)
    }

    @Test("Speed does not carry a gesture past where its fingers went")
    func speedDoesNotStandInForDistance() {
        // Momentum is deliberately not consulted, so throwing harder does not land the
        // reader pages further on than the fingers reached.
        let barelyMoved = width * 0.05
        for velocity in [flick, flick * 10, flick * 100] as [CGFloat] {
            #expect(settle(origin: 0, position: barelyMoved, velocity: velocity) == width)
        }
    }

    @Test("A flick on a long swipe does not overshoot the nearest page")
    func flickOnALongSwipeLandsNearest() {
        #expect(flicked(to: width * 3.2) == width * 3)
        #expect(flicked(to: width * 4.1) == width * 4)
    }

    @Test("Flicking backwards carries to the previous page")
    func flickBackwards() {
        #expect(flicked(from: width * 4, to: width * 4 - 80) == width * 3)
        #expect(dragged(from: width * 4, to: width * 4 - 80) == width * 4)
    }

    @Test("A gesture that goes nowhere does not turn, however fast it was")
    func motionlessGestureDoesNotTurn() {
        #expect(settle(origin: width * 2, position: width * 2, velocity: flick * 10) == width * 2)
        #expect(
            settle(
                origin: 0,
                position: ReaderPaging.minimumTravel - 1,
                velocity: flick * 10
            ) == 0
        )
    }

    @Test("A drag that is slow and tiny does nothing at all")
    func tinyDragDoesNothing() {
        #expect(dragged(to: 1) == 0)
        #expect(settle(origin: width * 3, position: width * 3 + 1, velocity: 0) == width * 3)
    }

    @Test("Degenerate input falls back to where the gesture started")
    func degenerateInput() {
        #expect(ReaderPaging.settleTarget(origin: 12, position: 900, pageWidth: 0, velocity: 0) == 12)
        #expect(ReaderPaging.settleTarget(origin: 12, position: 900, pageWidth: -5, velocity: 0) == 12)
        #expect(ReaderPaging.settleTarget(origin: 12, position: .nan, pageWidth: width, velocity: 0) == 12)
    }
}
