import Foundation
import Observation
import Testing
@testable import Azumanga

@Suite("MangaViewOptions", .serialized)
@MainActor
struct MangaViewOptionsTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "azumanga.manga-view-options.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeSettings(_ defaults: UserDefaults) -> SettingsStore {
        let settings = SettingsStore(defaults: defaults)
        settings.layout = .horizontal
        settings.direction = .rightToLeft
        settings.pageMode = .double
        settings.fitMode = .fitScreen
        settings.background = .white
        return settings
    }

    private func makeManga(_ id: String = "m1") -> Manga {
        Manga(sourceId: "test", mangaId: id, title: "Test Manga")
    }

    @Test("Uses global defaults until the manga is customized")
    func usesDefaults() {
        let defaults = makeDefaults()
        let settings = makeSettings(defaults)
        let store = MangaViewOptionsStore(defaults: defaults)
        let options = ReaderViewOptions(manga: makeManga(), defaults: settings, store: store)

        #expect(!options.usesCustomOptions)
        #expect(options.layout == .horizontal)
        #expect(options.direction == .rightToLeft)
        #expect(options.pageMode == .double)
        #expect(options.fitMode == .fitScreen)
        #expect(options.background == .white)
    }

    @Test("First change creates a complete per-manga snapshot")
    func firstChangeSnapshotsDefaults() {
        let defaults = makeDefaults()
        let settings = makeSettings(defaults)
        let store = MangaViewOptionsStore(defaults: defaults)
        let options = ReaderViewOptions(manga: makeManga(), defaults: settings, store: store)

        options.layout = .vertical

        #expect(options.usesCustomOptions)
        #expect(options.layout == .vertical)
        #expect(options.direction == .rightToLeft)
        #expect(options.pageMode == .double)
        #expect(options.fitMode == .fitScreen)
        #expect(options.background == .white)
        #expect(store.options(for: "test:m1")?.layout == .vertical)
    }

    @Test("Custom snapshots persist and ignore later default changes")
    func customSnapshotPersists() {
        let defaults = makeDefaults()
        let settings = makeSettings(defaults)
        let store = MangaViewOptionsStore(defaults: defaults)
        let manga = makeManga()
        let options = ReaderViewOptions(manga: manga, defaults: settings, store: store)

        options.background = .black
        settings.background = .white
        settings.layout = .vertical

        let reopenedStore = MangaViewOptionsStore(defaults: defaults)
        let reopened = ReaderViewOptions(
            manga: manga,
            defaults: settings,
            store: reopenedStore
        )
        #expect(reopened.usesCustomOptions)
        #expect(reopened.background == .black)
        #expect(reopened.layout == .horizontal)
    }

    @Test("Warmth is saved with the manga and clamped to its range")
    func warmthPersists() {
        let defaults = makeDefaults()
        let settings = makeSettings(defaults)
        let store = MangaViewOptionsStore(defaults: defaults)
        let manga = makeManga()
        let options = ReaderViewOptions(manga: manga, defaults: settings, store: store)

        options.warmth = 0.65

        let reopened = ReaderViewOptions(
            manga: manga,
            defaults: settings,
            store: MangaViewOptionsStore(defaults: defaults)
        )
        #expect(reopened.usesCustomOptions)
        #expect(abs(reopened.warmth - 0.65) < 0.000_001)

        options.warmth = 2
        #expect(options.warmth == 1)

        options.warmth = -1
        #expect(options.warmth == 0)
    }

    @Test("Views saved before warmth existed decode as unmodified")
    func legacyWarmthDefaultsToOff() throws {
        let json = """
        {
          "layout": "vertical",
          "direction": "leftToRight",
          "pageMode": "single",
          "fitMode": "fitScreen",
          "background": "white"
        }
        """

        let options = try JSONDecoder().decode(
            MangaViewOptions.self,
            from: Data(json.utf8)
        )

        #expect(options.warmth == 0)
        #expect(options.background == .white)

        let roundTrip = try JSONDecoder().decode(
            MangaViewOptions.self,
            from: JSONEncoder().encode(options)
        )
        #expect(roundTrip == options)
    }

    @Test("Reset removes the override and follows defaults again")
    func reset() {
        let defaults = makeDefaults()
        let settings = makeSettings(defaults)
        let store = MangaViewOptionsStore(defaults: defaults)
        let options = ReaderViewOptions(manga: makeManga(), defaults: settings, store: store)

        options.pageMode = .single
        options.resetToDefaults()

        #expect(!options.usesCustomOptions)
        #expect(options.pageMode == .double)
        #expect(store.options(for: "test:m1") == nil)
    }

    @Test("Overrides are keyed by source and manga")
    func overridesAreSeparate() {
        let defaults = makeDefaults()
        let settings = makeSettings(defaults)
        let store = MangaViewOptionsStore(defaults: defaults)
        let first = ReaderViewOptions(manga: makeManga("first"), defaults: settings, store: store)
        let second = ReaderViewOptions(manga: makeManga("second"), defaults: settings, store: store)

        first.pageMode = .single

        #expect(first.pageMode == .single)
        #expect(second.pageMode == .double)
        #expect(store.options(for: "test:first") != nil)
        #expect(store.options(for: "test:second") == nil)
    }

    @Test("Global default changes invalidate a manga without a custom view")
    func defaultsAreObserved() {
        let defaults = makeDefaults()
        let settings = makeSettings(defaults)
        let store = MangaViewOptionsStore(defaults: defaults)
        let options = ReaderViewOptions(manga: makeManga(), defaults: settings, store: store)

        final class Flag: @unchecked Sendable {
            var value = false
        }
        let changed = Flag()

        withObservationTracking {
            _ = options.layout
        } onChange: {
            changed.value = true
        }

        settings.layout = .vertical

        #expect(changed.value)
    }
}
