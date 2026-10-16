import Foundation
import SwiftData

/// Builds the SwiftData stack. The on-disk store lives in Application Support
/// (SwiftData's default), so the library and reading progress survive relaunch.
nonisolated enum PersistenceContainer {
    static var schema: Schema {
        Schema([
            LibraryEntry.self,
            MangaCategory.self,
            ReadingProgressRecord.self,
            BookmarkRecord.self,
            HistoryRecord.self,
            DownloadRecord.self,
            SourcePreferences.self,
        ])
    }

    static func make(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let schema = schema
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration(schema: schema, url: url)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// The app-wide store. Falls back to memory so the app still launches if the
    /// on-disk store is unavailable.
    static let shared: ModelContainer = {
        if let container = try? make() { return container }
        if let container = try? make(inMemory: true) { return container }
        fatalError("Unable to create a SwiftData ModelContainer")
    }()
}
