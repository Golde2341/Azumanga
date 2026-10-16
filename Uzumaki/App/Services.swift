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

    /// The external parser host, when one is available. `nil` means the Kotatsu
    /// sources are simply not offered.
    let kotatsuHost: KotatsuHostProcess?
    /// Why the parser host is unavailable, for the Sources screen.
    private(set) var kotatsuUnavailableReason: String?

    let libraryStore: LibraryStore
    let progressStore: ProgressStore
    let historyStore: HistoryStore
    let bookmarkStore: BookmarkStore
    let sourceStore: SourceStore
    let downloadStore: DownloadStore

    init(
        container: ModelContainer = PersistenceContainer.shared,
        http: HTTPClient = HTTPClient(),
        downloadDirectories: DownloadDirectories = DownloadDirectories(),
        kotatsuConfiguration: KotatsuHostConfiguration? = KotatsuHostLocator.resolve()
    ) {
        let registry = SourceRegistry()
        let sourceStore = SourceStore(context: container.mainContext)

        // One host process, shared by every Kotatsu source and by image fetching —
        // that is what lets it keep parser instances, cookies and rate limiting.
        let host = kotatsuConfiguration.map { KotatsuHostProcess(configuration: $0) }
        let imageResolver = host.map { KotatsuImageResolver(host: $0) }

        self.container = container
        self.context = container.mainContext
        self.http = http
        self.images = ImagePipeline(
            http: http,
            memory: MemoryImageCache(),
            disk: DiskImageCache(directory: DiskImageCache.defaultDirectory),
            hostResolver: imageResolver
        )
        self.registry = registry
        self.libraryStore = LibraryStore(context: container.mainContext)
        self.progressStore = ProgressStore(context: container.mainContext)
        self.historyStore = HistoryStore(context: container.mainContext)
        self.bookmarkStore = BookmarkStore(context: container.mainContext)
        self.sourceStore = sourceStore
        self.downloadStore = DownloadStore(context: container.mainContext)
        self.installer = SourceInstallService(registry: registry, http: http, sourceStore: sourceStore)
        self.downloads = DownloadManager(
            registry: registry,
            http: http,
            directories: downloadDirectories,
            hostResolver: imageResolver
        )

        self.kotatsuHost = host
        self.kotatsuUnavailableReason = host == nil
            ? "Kotatsu sources need a Java runtime. Install a JDK 17 (or ship the bundled runtime) to enable them."
            : nil
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
        await registerKotatsuSources()
    }

    /// Registers the curated Kotatsu sources from the parser host. Never throws:
    /// if the host cannot answer, the app simply offers no Kotatsu sources and the
    /// Sources screen explains why.
    private func registerKotatsuSources() async {
        guard let kotatsuHost else { return }

        do {
            let response = try await kotatsuHost.call(
                "sources",
                as: KotatsuSourceListDTO.self,
                timeout: .seconds(60)
            )

            var registered = 0
            for dto in response.items where KotatsuCatalog.isAllowed(dto.key) && !dto.broken {
                let source = KotatsuSource(source: dto, host: kotatsuHost)
                let stored = try? sourceStore.preferences(for: source.id)
                // Enabled by default on first run, so the feature is discoverable.
                let isEnabled = stored?.isEnabled ?? true

                await registry.register(source, isEnabled: isEnabled)
                _ = try? sourceStore.upsert(
                    sourceId: source.id,
                    name: source.name,
                    version: source.version,
                    isBuiltIn: false,
                    isEnabled: isEnabled
                )
                registered += 1
            }

            kotatsuUnavailableReason = registered == 0
                ? "The parser host is running but reported none of the curated sources."
                : nil
        } catch {
            kotatsuUnavailableReason = "The parser host could not be started: \(userFacingMessage(for: error))"
        }
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
