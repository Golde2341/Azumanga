import Foundation

/// Broad content categories used when choosing which parser sources to enable.
/// Kotatsu reports more granular types; several of them collapse into "Misc".
nonisolated enum SourceContentType: String, CaseIterable, Identifiable, Sendable {
    case manga
    case hentai
    case comics
    case misc
    case manhwa

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manga: "Manga"
        case .hentai: "Hentai"
        case .comics: "Comics"
        case .misc: "Misc"
        case .manhwa: "Manhwa"
        }
    }

    /// Categories enabled before the user makes a choice. Hentai sources are
    /// deliberately opt-in.
    static let safeDefaults: Set<SourceContentType> = [
        .manga, .comics, .misc, .manhwa,
    ]

    /// Maps a Kotatsu source's `contentType` onto one of the broad choices.
    static func category(for sourceContentType: String) -> SourceContentType {
        switch sourceContentType.uppercased() {
        case "MANGA":
            .manga
        case "MANHWA":
            .manhwa
        case "COMICS":
            .comics
        case "HENTAI", "DOUJINSHI":
            .hentai
        default:
            // MANHUA, NOVEL, ONE_SHOT, IMAGE_SET, ARTIST_CG, GAME_CG, OTHER…
            .misc
        }
    }
}
