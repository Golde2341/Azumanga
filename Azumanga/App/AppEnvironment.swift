import SwiftData
import SwiftUI

/// Owns the app's shared, MainActor-bound models. Created once at launch and
/// injected into the SwiftUI environment.
@MainActor
@Observable
final class AppEnvironment {
    let settings: SettingsStore
    let services: Services
    let library: LibraryModel
    let discovery: DiscoveryModel
    let sources: SourcesModel
    let downloads: DownloadsModel
    let healthChecker: SourceHealthChecker

    init(container: ModelContainer = PersistenceContainer.shared) {
        let settings = SettingsStore()
        let services = Services(container: container)
        let sources = SourcesModel(services: services)
        let healthChecker = SourceHealthChecker(services: services)

        self.settings = settings
        self.services = services
        self.library = LibraryModel(services: services)
        self.discovery = DiscoveryModel(services: services)
        self.sources = sources
        self.downloads = DownloadsModel(services: services)
        self.healthChecker = healthChecker

        // A bulk check can run for many minutes; the list should follow along.
        healthChecker.onResult = { [weak sources] sourceId, snapshot, isEnabled in
            sources?.applyHealth(snapshot, isEnabled: isEnabled, sourceId: sourceId)
        }
    }

    /// Registers sources and restores the user's enablement. Safe to call more
    /// than once; the registry upserts by identifier.
    func bootstrap() async {
        await services.bootstrapSources(using: settings)
        await sources.refresh()
    }

    /// Rebuilds provider instances after a settings change they depend on.
    func refreshProviders() async {
        await services.refreshSources(using: settings)
        await sources.refresh()
        await discovery.refreshSources()
    }
}
