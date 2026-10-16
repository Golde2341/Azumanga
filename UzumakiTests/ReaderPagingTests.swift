import Foundation
import Testing
@testable import Uzumaki

@Suite("Reader scroll limiting")
struct ReaderPagingTests {
    private let width: CGFloat = 800

    /// A speed at which distance no longer matters, and one where it half does.
    private let fullSpeed = ReaderPaging.fullSpeedVelocity
    private let halfSpeed = ReaderPaging.fullSpeedVelocity / 2

    /// Distance a *slow* drag has to cover to turn. Derived from the constant rather than
    /// hardcoded, so the tests express the policy and not the current numbers.
    private var slowTurnDistance: CGFloat { width * ReaderPaging.turnThreshold }

    private func settle(origin: CGFloat = 0, proposed: CGFloat, velocity: CGFloat) -> CGFloat {
        ReaderPaging.settleTarget(origin: origin, proposed: proposed, pageWidth: width, velocity: velocity)
    }

    @Test("A slow drag short of the turn distance springs back")
    func slowDragSpringsBack() {
        for travel in [0, 40, -20, slowTurnDistance - 1, -(slowTurnDistance - 1)] as [CGFloat] {
            #expect(settle(proposed: travel, velocity: 0) == 0)
        }
    }

    @Test("A slow drag past the turn distance turns exactly one page")
    func slowDragTurnsOnePage() {
        #expect(settle(proposed: slowTurnDistance + 1, velocity: 0) == width)
        #expect(settle(proposed: -(slowTurnDistance + 1), velocity: 0) == -width)
    }

    @Test("Scrolling fast turns the page well before it has crossed the screen")
    func speedShortensTheDistanceNeeded() {
        // A tenth of the screen: nowhere near half, and not far enough for a slow drag.
        let travel = width * 0.1
        #expect(travel < slowTurnDistance)
        #expect(settle(proposed: travel, velocity: 0) == 0)
        #expect(settle(proposed: travel, velocity: halfSpeed) == width)
    }

    @Test("The faster the gesture, the less distance it needs")
    func requiredDistanceFallsWithSpeed() {
        let travel: CGFloat = 140
        var turned: [Bool] = []
        for velocity in [0, 250, halfSpeed, fullSpeed] as [CGFloat] {
            turned.append(settle(proposed: travel, velocity: velocity) == width)
        }
        // Slow to fast: once speed is enough, more speed never takes the turn away.
        #expect(turned == [false, true, true, true])
    }

    @Test("At full speed any deliberate push turns the page")
    func fullSpeedTurnsOnAnyTravel() {
        let push = ReaderPaging.minimumTravel + 1
        #expect(settle(proposed: push, velocity: fullSpeed) == width)
        #expect(settle(proposed: -push, velocity: fullSpeed) == -width)
        #expect(settle(proposed: push, velocity: fullSpeed * 4) == width)
    }

    @Test("A gesture that is fast but goes nowhere does not turn")
    func fastButGoingNowhereDoesNotTurn() {
        #expect(settle(proposed: 0, velocity: fullSpeed * 4) == 0)
        #expect(settle(proposed: ReaderPaging.minimumTravel - 1, velocity: fullSpeed * 4) == 0)
    }

    @Test("No proposal can carry a gesture past the neighbouring page")
    func travelIsCappedAtOnePage() {
        for proposed in [width * 2, width * 10, width * 1_000] as [CGFloat] {
            #expect(settle(proposed: proposed, velocity: fullSpeed) == width)
        }
        for proposed in [-width * 2, -width * 1_000] as [CGFloat] {
            #expect(settle(proposed: proposed, velocity: fullSpeed) == -width)
        }
    }

    @Test("Resting places are always on the page grid")
    func settlesOnTheGrid() {
        let origin = width * 3
        #expect(settle(origin: origin, proposed: origin + 10, velocity: 0) == origin)
        #expect(settle(origin: origin, proposed: origin + slowTurnDistance + 1, velocity: 0) == origin + width)
        #expect(settle(origin: origin, proposed: origin - slowTurnDistance - 1, velocity: 0) == origin - width)
    }

    @Test("An origin left off the grid by a resize is snapped back on to it")
    func offGridOriginIsSnapped() {
        #expect(settle(origin: 37, proposed: 40, velocity: 0) == 0)
        #expect(settle(origin: 37, proposed: 900, velocity: 0) == width)
    }

    @Test("Both directions behave alike")
    func symmetric() {
        for travel in [width * 0.1, width * 0.7, width * 2] as [CGFloat] {
            let forward = settle(proposed: travel, velocity: fullSpeed)
            let backward = settle(proposed: -travel, velocity: fullSpeed)
            #expect(forward == -backward)
        }
    }

    @Test("Degenerate input leaves the position where it was")
    func degenerateInput() {
        #expect(ReaderPaging.settleTarget(origin: 12, proposed: 900, pageWidth: 0, velocity: 0) == 12)
        #expect(ReaderPaging.settleTarget(origin: 12, proposed: 900, pageWidth: -5, velocity: 0) == 12)
        #expect(ReaderPaging.settleTarget(origin: 12, proposed: .nan, pageWidth: width, velocity: 0) == 12)
    }
}
