import Foundation

/// A complete per-manga reading view. Created from the global defaults the first
/// time a reader changes one of the view controls, then saved independently.
nonisolated struct MangaViewOptions: Codable, Equatable, Sendable {
    var layout: ReaderLayoutKind
    var direction: ReadingDirection
    var pageMode: PageMode
    var fitMode: PageFitMode
    var background: PageBackground
    /// Page tint from 0 (unchanged) to 1 (white point `#f1e1c9`).
    var warmth: Double

    init(
        layout: ReaderLayoutKind,
        direction: ReadingDirection,
        pageMode: PageMode,
        fitMode: PageFitMode,
        background: PageBackground,
        warmth: Double = 0
    ) {
        self.layout = layout
        self.direction = direction
        self.pageMode = pageMode
        self.fitMode = fitMode
        self.background = background
        self.warmth = Self.clampedWarmth(warmth)
    }

    @MainActor
    init(defaults: SettingsStore) {
        self.init(
            layout: defaults.layout,
            direction: defaults.direction,
            pageMode: defaults.pageMode,
            fitMode: defaults.fitMode,
            background: defaults.background
        )
    }

    private enum CodingKeys: String, CodingKey {
        case layout
        case direction
        case pageMode
        case fitMode
        case background
        case warmth
    }

    /// Decode views saved before warmth existed as an unmodified page.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layout = try container.decode(ReaderLayoutKind.self, forKey: .layout)
        direction = try container.decode(ReadingDirection.self, forKey: .direction)
        pageMode = try container.decode(PageMode.self, forKey: .pageMode)
        fitMode = try container.decode(PageFitMode.self, forKey: .fitMode)
        background = try container.decode(PageBackground.self, forKey: .background)
        warmth = Self.clampedWarmth(
            try container.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
        )
    }

    private static func clampedWarmth(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
