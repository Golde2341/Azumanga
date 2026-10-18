import Foundation

/// A complete per-manga reading view. Created from the global defaults the first
/// time a reader changes one of the view controls, then saved independently.
nonisolated struct MangaViewOptions: Codable, Equatable, Sendable {
    var layout: ReaderLayoutKind
    var direction: ReadingDirection
    var pageMode: PageMode
    var fitMode: PageFitMode
    var background: PageBackground

    init(
        layout: ReaderLayoutKind,
        direction: ReadingDirection,
        pageMode: PageMode,
        fitMode: PageFitMode,
        background: PageBackground
    ) {
        self.layout = layout
        self.direction = direction
        self.pageMode = pageMode
        self.fitMode = fitMode
        self.background = background
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
}
