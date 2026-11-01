import SwiftUI

/// Where a horizontal gesture is allowed to come to rest.
///
/// The point of this is what it does *not* do. A scroll view will happily report a target
/// calculated from the gesture's deceleration, so a fast swipe lands several pages along —
/// pages that flew past too quickly to read. Wanted instead is the desktop swipe: the
/// pages track the fingers, and letting go settles on whichever page is nearest to where
/// they stopped. The gesture's own momentum is therefore ignored, and only its speed is
/// consulted, to carry a flick that stopped short of the halfway point on to the next page.
///
/// The arithmetic lives here, apart from the conformance, so it can be tested directly.
nonisolated enum ReaderPaging {
    /// Speed, in points per second, at or above which a gesture counts as a flick and
    /// turns at least one page however little it moved.
    static let fullSpeedVelocity: CGFloat = 1000

    /// Least a gesture must move to be considered a flick at all, so that a stray tick of
    /// velocity on a stationary gesture cannot turn a page.
    static let minimumTravel: CGFloat = 2

    /// The offset to settle on.
    ///
    /// - Parameters:
    ///   - origin: The offset the gesture started from.
    ///   - position: The offset the fingers had reached when they let go, without momentum.
    ///   - pageWidth: The width of one spread.
    ///   - velocity: How fast the gesture was moving.
    static func settleTarget(
        origin: CGFloat,
        position: CGFloat,
        pageWidth: CGFloat,
        velocity: CGFloat
    ) -> CGFloat {
        guard pageWidth > 0, pageWidth.isFinite, origin.isFinite, position.isFinite else {
            // Nothing sensible to snap to, and never hand the scroll view a NaN: fall back
            // to where the gesture started.
            return origin
        }

        // Nearest page to wherever the fingers stopped. Being nearest is what lets a long
        // swipe cross as many pages as it covers rather than being capped at one.
        let pages = position / pageWidth
        let nearest = pages.rounded() * pageWidth

        let travel = position - origin
        guard abs(travel) >= minimumTravel, abs(velocity) >= fullSpeedVelocity else {
            return nearest
        }

        // A flick is a decision already made. It carries on to the next page when the
        // fingers stopped short of it, and takes the nearest page when they did not.
        let originPage = (origin / pageWidth).rounded()
        let carried = travel > 0
            ? max(pages.rounded(), originPage + 1)
            : min(pages.rounded(), originPage - 1)
        return carried * pageWidth
    }
}

/// Carries the scroll view's live offset out to `ReaderPagingBehavior`.
///
/// A scroll target behavior is handed the offset a gesture *would* reach once its
/// deceleration had played out, which is not the offset the fingers let go at. That one is
/// only knowable from the scroll view itself, so it is kept here and read when the gesture
/// ends.
///
/// Deliberately neither observable nor a value type: it is written on every frame of a
/// scroll and read only inside `updateTarget`, both on the main thread, so it must not
/// invalidate the view and must not be copied at the moment it is needed.
nonisolated final class ReaderScrollOffset: @unchecked Sendable {
    var value: CGFloat = 0
    /// While true the paging behavior leaves the scroll target where the layout put
    /// it.
    ///
    /// A full-screen frame change rewrites the spread width on every frame of the
    /// animation, and the offset is moving with it. Rounding the position to the
    /// nearest spread against a width that is itself changing rounds onto a
    /// neighbour, which shows as the row scrolling toward the next page and snapping
    /// back for the length of the animation. Nothing is gestured while the window
    /// animates, so there is nothing for the behavior to settle.
    ///
    /// This lives on the shared object rather than on the behavior struct because the
    /// struct is captured when the view body is evaluated, which races the animation;
    /// a value read here is always current.
    var isSuppressed = false
}

/// Applies `ReaderPaging` to the reader's horizontal scroll view.
///
/// The scroll view still follows the fingers and still rubber-bands at its ends on its own;
/// this only overrides where a gesture comes to rest.
nonisolated struct ReaderPagingBehavior: ScrollTargetBehavior {
    /// Width of one spread, which is the width of the scroll view's container.
    let pageWidth: CGFloat
    /// The scroll view's live offset, and whether this behavior is standing down.
    let offset: ReaderScrollOffset

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard !offset.isSuppressed else { return }
        target.rect.origin.x = ReaderPaging.settleTarget(
            origin: context.originalTarget.rect.minX,
            position: offset.value,
            pageWidth: pageWidth,
            velocity: context.velocity.dx
        )
    }
}
