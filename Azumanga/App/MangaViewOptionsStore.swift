import Foundation
import Observation

/// Stores per-manga view overrides. Kept separate from `SettingsStore` so the
/// settings window is always the fallback/default, not a global override.
@MainActor
@Observable
final class MangaViewOptionsStore {
    private static let storageKey = "reader.mangaViewOptions.v1"

    @ObservationIgnored private let defaults: UserDefaults
    private var records: [String: MangaViewOptions]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: MangaViewOptions].self, from: data) {
            self.records = decoded
        } else {
            self.records = [:]
        }
    }

    func options(for mangaKey: String) -> MangaViewOptions? {
        records[mangaKey]
    }

    func save(_ options: MangaViewOptions, for mangaKey: String) {
        records[mangaKey] = options
        persist()
    }

    func remove(for mangaKey: String) {
        guard records.removeValue(forKey: mangaKey) != nil else { return }
        persist()
    }

    func removeAll() {
        guard !records.isEmpty else { return }
        records.removeAll()
        persist()
    }

    var customMangaCount: Int { records.count }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
