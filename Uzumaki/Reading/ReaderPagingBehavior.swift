import SwiftUI

/// How far a single scroll gesture is allowed to move the horizontal reader.
///
/// The reader wants the next page to be reachable without dragging it the whole way
/// across the screen, and to never travel further than that neighbour. Both are really the
/// same question — where a gesture is allowed to come to rest — which is what a
/// `ScrollTargetBehavior` answers.
///
/// The arithmetic lives here, apart from the conformance, so it can be tested directly.
nonisolated enum ReaderPaging {
    /// Fraction of a page a *slow* drag must cover before it turns.
    static let turnThreshold: CGFloat = 0.2

    /// Speed, in points per second, at which distance stops mattering. At or above this,
    /// any deliberate push turns the page, however little of it has crossed the screen.
    static let fullSpeedVelocity: CGFloat = 1000

    /// Least travel that can count as a turn, so that a gesture which is fast but goes
    /// nowhere cannot turn the page on speed alone.
    static let minimumTravel: CGFloat = 4

    /// Where a gesture should settle, given where it started, where the scroll view would
    /// land on its own, and how fast the fingers were moving when it ended.
    ///
    /// The result is always the page the gesture started on or one of its immediate
    /// neighbours, so a gesture can never carry the reader further than the next spread.
    static func settleTarget(
        origin: CGFloat,
        proposed: CGFloat,
        pageWidth: CGFloat,
        velocity: CGFloat
    ) -> CGFloat {
        guard pageWidth > 0, pageWidth.isFinite, origin.isFinite, proposed.isFinite else {
            return origin
        }

        // Snap the starting point on to the page grid. It is already on it during normal
        // scrolling; this matters after a resize has changed how wide a page is, where
        // an offset from the old grid would otherwise leave the reader between pages.
        let page = (origin / pageWidth).rounded() * pageWidth
        let travel = proposed - page

        // The faster the gesture, the less of the page it has to cross. A flick is a
        // decision already made by the time the fingers lift, so making it wait for a
        // fixed line means the page arrives late, or not at all.
        let easing = max(0, 1 - abs(velocity) / fullSpeedVelocity)
        let required = max(minimumTravel, pageWidth * turnThreshold * easing)

        guard abs(travel) >= required else { return page }

        return page + (travel > 0 ? pageWidth : -pageWidth)
    }
}

/// Applies `ReaderPaging` to the reader's horizontal scroll view.
///
/// The scroll view still follows the fingers and still rubber-bands on its own; this only
/// overrides where a gesture comes to rest.
nonisolated struct ReaderPagingBehavior: ScrollTargetBehavior {
    /// Width of one spread, which is the width of the scroll view's container.
    let pageWidth: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let settled = ReaderPaging.settleTarget(
            origin: context.originalTarget.rect.minX,
            proposed: target.rect.minX,
            pageWidth: pageWidth,
            velocity: context.velocity.dx
        )
        target.rect.origin.x = settled
    }
}
