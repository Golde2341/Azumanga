import Foundation

/// Which Kotatsu sources the app offers.
///
/// The registry contains ~1370 sources and the host reports ~428 of them as broken
/// upstream. Rather than curate to a handful by guesswork, the app registers
/// everything and lets you check them: **Settings ▸ Sources ▸ Check All Sources**
/// probes each one, switches off what fails, and records the result.
///
/// A small default-on set ships so the app is usable before any check has run.
nonisolated enum KotatsuCatalog {
    /// Sources deliberately never registered.
    ///
    /// - `MANGADEX`: a native Swift source already provides it, and two entries with
    ///   the same name in the source picker would be confusing.
    static let neverRegistered: [String: String] = [
        "MANGADEX": "covered by the built-in native source",
    ]

    /// Enabled on first run, before any health check.
    ///
    /// Measured, not guessed: each of these was read end to end through the host —
    /// browse, search, details, pages, and a real page image — by probing the
    /// catalogue. Sources that only serve adult content are deliberately left off
    /// this list; they still appear in the check and can be enabled by hand.
    static let enabledByDefault: [String] = [
        "ANISASCANS",
        "ARENASCANS",
        "ASURASCANS",
        "DECADENCESCANS",
        "EZMANGA",
        "GEDECOMIX",
        "GRABBER",
        "KEWNSCANS",
        "KSGROUPSCANS",
        "LAGOONSCANS",
        "LHTRANSLATION",
        "LIKEMANGA",
        "MANGABEE",
        "MANGADASS",
        "MANGADNA",
        "MANGAECLIPSE",
        "MANGAFREAK",
        "MANGAGG",
        "MANGAMANIACS",
        "MANGAOWL_IO",
        "MANGAPILL",
        "MANGAREAD",
        "MANGASUSHI",
        "MANGATELLERS",
        "MANGA_DISTRICT",
        "MANHUAHOT",
        "MANHUAPLUS",
        "MANHWADEN",
        "OMEGASCANS",
        "PARITEHABER",
        "PETROTECHSOCIETY",
        "RACKUSREADS",
        "RAVENSCANS",
        "ROKARICOMICS",
        "S2MANGA",
        "SHOJOSCANS",
        "SURYASCANS",
        "TOONILY",
        "TOONIZY",
        "TOPMANHUA",
        "TRITINIA",
        "YAKSHACOMICS",
    ]

    static func isRegistered(_ key: String) -> Bool {
        neverRegistered[key] == nil
    }

    static func isEnabledByDefault(_ key: String) -> Bool {
        enabledByDefault.contains(key)
    }
}
