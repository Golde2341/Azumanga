import Foundation
import SwiftData
import SwiftUI

/// Composition root for the app's long-lived services. Created once and shared
/// through the SwiftUI environment; holds the SwiftData stack, networking,
/// imaging and the source registry.
@MainActor
@Observable
final class Services {
    let container: ModelContainer
    let context: ModelContext

    let http: HTTPClient
    let images: ImagePipeline
    let registry: SourceRegistry
    let installer: SourceInstallService
    let downloads: DownloadManager

    let libraryStore: LibraryStore
    let progressStore: ProgressStore
    let historyStore: HistoryStore
    let bookmarkStore: BookmarkStore
    let sourceStore: SourceStore
    let downloadStore: DownloadStore

    init(
        container: ModelContainer = PersistenceContainer.shared,
        http: HTTPClient = HTTPClient(),
        downloadDirectories: DownloadDirectories = DownloadDirectories()
    ) {
        let registry = SourceRegistry()
        let sourceStore = SourceStore(context: container.mainContext)

        self.container = container
        self.context = container.mainContext
        self.http = http
        self.images = ImagePipeline(
            http: http,
            memory: MemoryImageCache(),
            disk: DiskImageCache(directory: DiskImageCache.defaultDirectory)
        )
        self.registry = registry
        self.libraryStore = LibraryStore(context: container.mainContext)
        self.progressStore = ProgressStore(context: container.mainContext)
        self.historyStore = HistoryStore(context: container.mainContext)
        self.bookmarkStore = BookmarkStore(context: container.mainContext)
        self.sourceStore = sourceStore
        self.downloadStore = DownloadStore(context: container.mainContext)
        self.installer = SourceInstallService(registry: registry, http: http, sourceStore: sourceStore)
        self.downloads = DownloadManager(registry: registry, http: http, directories: downloadDirectories)
    }

    /// Registers the compiled-in sources plus any installed providers, restoring
    /// the user's enablement the first time or when stored state already exists.
    func bootstrapSources(using settings: SettingsStore) async {
        let stored = (try? sourceStore.all()) ?? []
        let hasStoredState = !stored.isEmpty
        let enabledIds: Set<String>? = hasStoredState
            ? Set(stored.filter(\.isEnabled).map(\.sourceId))
            : nil

        let sources = BuiltinSources.make(configuration: settings.mangaDexConfiguration, http: http)
        await registry.register(contentsOf: sources, enabledIds: enabledIds)

        for source in sources {
            _ = try? sourceStore.upsert(
                sourceId: source.id,
                name: source.name,
                version: source.version,
                isBuiltIn: source.isBuiltIn,
                isEnabled: await registry.isEnabled(id: source.id)
            )
        }

        await installer.loadInstalledSources()
    }

    /// Rebuilds provider instances after a settings change that affects them
    /// (e.g. image quality or translated language).
    func refreshSources(using settings: SettingsStore) async {
        let enabled = Set(await registry.enabledInfos().map(\.id))
        for source in BuiltinSources.make(configuration: settings.mangaDexConfiguration, http: http) {
            await registry.register(source, isEnabled: enabled.isEmpty || enabled.contains(source.id))
        }
    }
}
