import Foundation

/// Maps between a position along the reader's progress bar and a page.
///
/// Kept apart from the view so the ends are testable: the bar's far end is the last page,
/// not the page after it, which is the off-by-one worth pinning down.
nonisolated enum ReaderScrubbing {
    /// The page a position along the bar asks for. `fraction` runs 0 to 1.
    static func page(atFraction fraction: CGFloat, pageCount: Int) -> Int {
        guard pageCount > 1 else { return 0 }
        let clamped = min(max(fraction, 0), 1)
        return Int((clamped * CGFloat(pageCount - 1)).rounded())
    }

    /// Where the bar should sit for a page, from 0 to 1.
    static func fraction(ofPage page: Int, pageCount: Int) -> CGFloat {
        guard pageCount > 1 else { return 0 }
        let clamped = min(max(page, 0), pageCount - 1)
        return CGFloat(clamped) / CGFloat(pageCount - 1)
    }
}
