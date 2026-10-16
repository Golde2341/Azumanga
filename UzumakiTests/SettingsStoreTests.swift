import Foundation
import Testing
@testable import Uzumaki

@Suite("SettingsStore")
struct SettingsStoreTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "uzumaki.settings.\(UUID().uuidString)")!
    }

    @Test("Fresh settings use sensible defaults")
    func defaults() {
        let settings = SettingsStore(defaults: makeDefaults())
        #expect(settings.layout == .vertical)
        #expect(settings.direction == .leftToRight)
        #expect(settings.pageMode == .single)
        #expect(!settings.readerFullscreen)
        #expect(settings.prefetchDistance == 3)
    }

    @Test("Reader preferences survive a relaunch")
    func persistence() {
        let defaults = makeDefaults()
        let before = SettingsStore(defaults: defaults)
        before.readerFullscreen = true
        before.layout = .horizontal
        before.direction = .rightToLeft
        before.pageMode = .double
        before.prefetchDistance = 6

        // A second store over the same defaults stands in for a relaunch.
        let after = SettingsStore(defaults: defaults)
        #expect(after.readerFullscreen)
        #expect(after.layout == .horizontal)
        #expect(after.direction == .rightToLeft)
        #expect(after.pageMode == .double)
        #expect(after.prefetchDistance == 6)
    }

    @Test("Content rating selection maps onto the provider configuration")
    func providerConfiguration() {
        let settings = SettingsStore(defaults: makeDefaults())
        settings.language = "es"
        settings.prefersDataSaver = false
        settings.contentRatings = [.safe]

        let configuration = settings.mangaDexConfiguration
        #expect(configuration.language == "es")
        #expect(configuration.quality == .data)
        #expect(configuration.contentRatings == [.safe])
    }

    @Test("An empty rating selection falls back to safe defaults")
    func emptyRatingsFallBack() {
        let settings = SettingsStore(defaults: makeDefaults())
        settings.contentRatings = []
        #expect(settings.mangaDexConfiguration.contentRatings == ContentRating.safeDefaults)
    }
}
