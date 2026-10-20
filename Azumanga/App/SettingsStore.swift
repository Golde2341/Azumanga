import Foundation
import SwiftUI

/// User preferences, persisted to `UserDefaults`. Reading settings live here so
/// both the reader and the source configuration can read them.
@MainActor
@Observable
final class SettingsStore {
    private enum Key: String {
        case layout
        case direction
        case pageMode
        case fitMode
        case background
        case pageQuality
        case contentRatings
        case language
        case prefetchDistance
        case doublePageFirstPageAlone
        case readerFullscreen
    }

    @ObservationIgnored private let defaults: UserDefaults

    var layout: ReaderLayoutKind {
        didSet { defaults.set(layout.rawValue, forKey: Key.layout.rawValue) }
    }

    var direction: ReadingDirection {
        didSet { defaults.set(direction.rawValue, forKey: Key.direction.rawValue) }
    }

    var pageMode: PageMode {
        didSet { defaults.set(pageMode.rawValue, forKey: Key.pageMode.rawValue) }
    }

    var fitMode: PageFitMode {
        didSet { defaults.set(fitMode.rawValue, forKey: Key.fitMode.rawValue) }
    }

    var background: PageBackground {
        didSet { defaults.set(background.rawValue, forKey: Key.background.rawValue) }
    }

    /// `true` prefers MangaDex's compressed `data-saver` images.
    var prefersDataSaver: Bool {
        didSet { defaults.set(prefersDataSaver, forKey: Key.pageQuality.rawValue) }
    }

    var contentRatings: Set<ContentRating> {
        didSet { defaults.set(contentRatings.map(\.rawValue).sorted(), forKey: Key.contentRatings.rawValue) }
    }

    /// Hides erotica and pornographic manga from source listings and search results.
    /// Turning it off includes every rating, matching the old adult-content picker.
    var hideNSFWResults: Bool {
        get { !contentRatings.contains(where: \.isNSFW) }
        set { contentRatings = newValue ? ContentRating.safeDefaults : Set(ContentRating.allCases) }
    }

    var language: String {
        didSet { defaults.set(language, forKey: Key.language.rawValue) }
    }

    /// How many pages ahead of the current one to prefetch.
    var prefetchDistance: Int {
        didSet { defaults.set(prefetchDistance, forKey: Key.prefetchDistance.rawValue) }
    }

    /// In double-page mode, show the first page alone so spreads stay aligned.
    var doublePageFirstPageAlone: Bool {
        didSet { defaults.set(doublePageFirstPageAlone, forKey: Key.doublePageFirstPageAlone.rawValue) }
    }

    /// Remembered so reopening the reader restores the window state you left it in.
    var readerFullscreen: Bool {
        didSet { defaults.set(readerFullscreen, forKey: Key.readerFullscreen.rawValue) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.layout = ReaderLayoutKind(rawValue: defaults.string(forKey: Key.layout.rawValue) ?? "") ?? .vertical
        self.direction = ReadingDirection(rawValue: defaults.string(forKey: Key.direction.rawValue) ?? "") ?? .leftToRight
        self.pageMode = PageMode(rawValue: defaults.string(forKey: Key.pageMode.rawValue) ?? "") ?? .single
        self.fitMode = PageFitMode(rawValue: defaults.string(forKey: Key.fitMode.rawValue) ?? "") ?? .fitScreen
        self.background = PageBackground(rawValue: defaults.string(forKey: Key.background.rawValue) ?? "") ?? .black
        self.prefersDataSaver = defaults.object(forKey: Key.pageQuality.rawValue) as? Bool ?? true
        self.language = defaults.string(forKey: Key.language.rawValue) ?? "en"
        self.prefetchDistance = defaults.object(forKey: Key.prefetchDistance.rawValue) as? Int ?? 3
        self.doublePageFirstPageAlone = defaults.object(forKey: Key.doublePageFirstPageAlone.rawValue) as? Bool ?? true
        self.readerFullscreen = defaults.object(forKey: Key.readerFullscreen.rawValue) as? Bool ?? false

        let ratings = defaults.stringArray(forKey: Key.contentRatings.rawValue)?
            .compactMap(ContentRating.init(rawValue:))
        self.contentRatings = Set(ratings ?? Array(ContentRating.safeDefaults).map(\.rawValue).compactMap(ContentRating.init(rawValue:)))
    }

    /// The quality setting in the form the MangaDex provider expects.
    var mangaDexQuality: MangaDexQuality {
        prefersDataSaver ? .dataSaver : .data
    }

    var mangaDexConfiguration: MangaDexConfiguration {
        MangaDexConfiguration(
            language: language,
            quality: mangaDexQuality,
            contentRatings: contentRatings.isEmpty ? ContentRating.safeDefaults : contentRatings
        )
    }

    var backgroundColor: Color {
        switch background {
        case .black: .black
        case .darkGray: Color(white: 0.12)
        case .white: .white
        }
    }
}
