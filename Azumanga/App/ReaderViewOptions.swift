import Foundation
import Observation

/// The effective view for one reader window: a per-manga override when one exists,
/// otherwise the defaults from the main Settings window.
@MainActor
@Observable
final class ReaderViewOptions {
    let mangaKey: String

    @ObservationIgnored private let defaults: SettingsStore
    @ObservationIgnored private let store: MangaViewOptionsStore
    private(set) var customOptions: MangaViewOptions?

    init(
        manga: Manga,
        defaults: SettingsStore,
        store: MangaViewOptionsStore
    ) {
        self.mangaKey = manga.id
        self.defaults = defaults
        self.store = store
        self.customOptions = store.options(for: manga.id)
    }

    var usesCustomOptions: Bool { customOptions != nil }

    var layout: ReaderLayoutKind {
        get { customOptions?.layout ?? defaults.layout }
        set { update { $0.layout = newValue } }
    }

    var direction: ReadingDirection {
        get { customOptions?.direction ?? defaults.direction }
        set { update { $0.direction = newValue } }
    }

    var pageMode: PageMode {
        get { customOptions?.pageMode ?? defaults.pageMode }
        set { update { $0.pageMode = newValue } }
    }

    var fitMode: PageFitMode {
        get { customOptions?.fitMode ?? defaults.fitMode }
        set { update { $0.fitMode = newValue } }
    }

    var background: PageBackground {
        get { customOptions?.background ?? defaults.background }
        set { update { $0.background = newValue } }
    }

    /// A warm page tint. `0` leaves pages untouched; `1` maps white to `#f1e1c9`.
    var warmth: Double {
        get { customOptions?.warmth ?? 0 }
        set {
            let clamped = min(max(newValue, 0), 1)
            update { $0.warmth = clamped }
        }
    }

    func resetToDefaults() {
        customOptions = nil
        store.remove(for: mangaKey)
    }

    func apply(_ preset: ReaderPreset) {
        update {
            $0.layout = preset.layout
            $0.pageMode = preset.pageMode
        }
    }

    private func update(_ mutate: (inout MangaViewOptions) -> Void) {
        // A custom view is a complete snapshot, not a sparse set of disabled
        // controls. Later changes to the defaults therefore do not partially leak
        // into a manga the user has already configured.
        var options = customOptions ?? MangaViewOptions(defaults: defaults)
        mutate(&options)
        customOptions = options
        store.save(options, for: mangaKey)
    }
}
