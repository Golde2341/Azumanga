import Foundation

/// Providers compiled into the app. Keeping construction here means the rest of
/// the app only ever sees `MangaSource` values.
@MainActor
enum BuiltinSources {
    static func make(configuration: MangaDexConfiguration = .default, http: HTTPClient) -> [any MangaSource] {
        [
            MangaDexSource(configuration: configuration, client: http),
        ]
    }
}
