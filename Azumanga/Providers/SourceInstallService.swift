import Foundation
import os

/// Installs, removes and reconfigures third-party providers, keeping the
/// on-disk store, the persisted preferences and the live registry in sync.
@MainActor
final class SourceInstallService {
    private let registry: SourceRegistry
    private let http: HTTPClient
    private let sourceStore: SourceStore
    let store: InstalledSourceStore
    private let log: Logger

    init(
        registry: SourceRegistry,
        http: HTTPClient,
        sourceStore: SourceStore,
        store: InstalledSourceStore = InstalledSourceStore(),
        log: Logger = Logger(subsystem: "org.azumanga", category: "providers")
    ) {
        self.registry = registry
        self.http = http
        self.sourceStore = sourceStore
        self.store = store
        self.log = log
    }

    // MARK: - Bootstrap

    /// Loads every installed provider into the registry. Returns the IDs that
    /// failed to load, with a reason, so the UI can report them.
    @discardableResult
    func loadInstalledSources() async -> [String: String] {
        let loaded = store.loadAll()
        var failures = loaded.failures
        for installed in loaded.sources {
            let preferences = try? sourceStore.preferences(for: installed.manifest.id)
            let config = configuration(for: installed.manifest, stored: preferences?.config)
            do {
                let source = try makeSource(from: installed, configuration: config)
                await registry.register(source, isEnabled: preferences?.isEnabled ?? true)
            } catch {
                failures[installed.manifest.id] = userFacingMessage(for: error)
                log.error("Failed to load provider \(installed.manifest.id, privacy: .public): \(userFacingMessage(for: error), privacy: .public)")
            }
        }
        return failures
    }

    func installedManifests() -> [SourceManifest] {
        store.installedSourceIDs().compactMap { try? store.load(id: $0).manifest }
    }

    func manifest(for id: String) -> SourceManifest? {
        try? store.load(id: id).manifest
    }

    /// Merges stored values over the manifest defaults so new fields get a value.
    func configuration(for manifest: SourceManifest, stored: [String: String]?) -> [String: String] {
        var values = manifest.defaultConfiguration
        for (key, value) in stored ?? [:] {
            values[key] = value
        }
        return values
    }

    // MARK: - Install / remove

    func install(_ package: SourcePackage, force: Bool = false) async throws {
        let installed = try store.install(package, force: force)
        let existing = try? sourceStore.preferences(for: installed.manifest.id)
        let config = configuration(for: installed.manifest, stored: existing?.config)
        let enabled = existing?.isEnabled ?? true

        _ = try sourceStore.upsert(
            sourceId: installed.manifest.id,
            name: installed.manifest.name,
            version: installed.manifest.version,
            isBuiltIn: false,
            isEnabled: enabled,
            config: config
        )

        let source = try makeSource(from: installed, configuration: config)
        await registry.register(source, isEnabled: enabled)
        log.info("Installed provider \(installed.manifest.id, privacy: .public) v\(installed.manifest.version, privacy: .public)")
    }

    func remove(id: String) async throws {
        guard store.isInstalled(id) else {
            throw SourceManifestError.notInstalled(id)
        }
        try store.remove(id: id)
        await registry.unregister(id: id)
        try sourceStore.remove(sourceId: id)
        log.info("Removed provider \(id, privacy: .public)")
    }

    /// Rebuilds a provider instance with new configuration and re-registers it.
    func updateConfiguration(id: String, config: [String: String]) async throws {
        let installed = try store.load(id: id)
        let merged = configuration(for: installed.manifest, stored: config)
        try sourceStore.setConfig(merged, sourceId: id)

        let preferences = try? sourceStore.preferences(for: id)
        let source = try makeSource(from: installed, configuration: merged)
        await registry.register(source, isEnabled: preferences?.isEnabled ?? true)
    }

    // MARK: - Sample provider

    /// The provider shipped inside the app, used to demonstrate that a provider
    /// can be installed at runtime without rebuilding the app.
    static func bundledSamplePackage() throws -> SourcePackage {
        guard let manifestURL = Bundle.main.url(forResource: "SampleProvider.manifest", withExtension: "json"),
              let scriptURL = Bundle.main.url(forResource: "SampleProvider.index", withExtension: "js")
        else {
            throw SourceManifestError.invalidField("sample", reason: "the bundled sample provider is missing")
        }
        let manifest = try SourceManifest.decodeAndValidate(Data(contentsOf: manifestURL))
        guard let script = String(data: try Data(contentsOf: scriptURL), encoding: .utf8) else {
            throw SourceManifestError.missingScript
        }
        return SourcePackage(manifest: manifest, script: script)
    }

    // MARK: - Private

    private func makeSource(from installed: InstalledSource, configuration: [String: String]) throws -> JSProviderSource {
        let providerId = installed.manifest.id
        let log = self.log
        return try JSProviderSource(
            manifest: installed.manifest,
            script: installed.script,
            configuration: configuration,
            http: http,
            log: { message in log.debug("[\(providerId, privacy: .public)] \(message, privacy: .public)") }
        )
    }
}
