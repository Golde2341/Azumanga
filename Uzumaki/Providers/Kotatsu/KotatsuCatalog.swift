import Foundation

/// Which Kotatsu sources the app offers.
///
/// This is an explicit allow-list rather than "all 1370", because the corpus is far
/// rougher than its size suggests: the host reports 428 sources as broken, and many
/// that aren't flagged still fail in practice. Membership here is based on measured
/// behaviour, not on the source's metadata.
///
/// The excluded list below is kept as documentation so this doesn't silently drift.
nonisolated enum KotatsuCatalog {
    /// Verified end to end through the host: browse, search, details, pages, and a
    /// fetchable page image.
    static let verified: [String] = [
        "MANGAPILL",
    ]

    /// Browsable, but not fully verified (search gaps, or images unconfirmed).
    static let candidates: [String] = [
        "ASURASCANS",
    ]

    /// Deliberately not offered, with the observed reason.
    ///
    /// - `MANGADEX`: a native Swift source already covers it; two entries would
    ///   confuse the source picker.
    /// - `COMICK_FUN`: requires JavaScript evaluation, which the host does not
    ///   implement yet (`evaluateJs`), so every search fails.
    /// - `KUNMANGA`, `ASURASCANSGG`: Cloudflare returns 403 to the host.
    /// - `MANGAKAKALOT`: the site now returns 404 for the parser's URL shape.
    /// - `MANGAREADERTO`: upstream returns 522.
    /// - `ASURASCANS_US`: 403 from the host.
    static let excludedReasons: [String: String] = [
        "MANGADEX": "covered by the built-in native source",
        "COMICK_FUN": "needs JavaScript evaluation (not implemented in the host)",
        "KUNMANGA": "Cloudflare blocks the host (403)",
        "ASURASCANSGG": "Cloudflare blocks the host (403)",
        "MANGAKAKALOT": "the site returns 404",
        "MANGAREADERTO": "upstream returns 522",
        "ASURASCANS_US": "403 from the host",
    ]

    static var allowedKeys: [String] {
        verified + candidates
    }

    static func isAllowed(_ key: String) -> Bool {
        allowedKeys.contains(key)
    }
}
