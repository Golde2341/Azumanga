import Foundation
import SwiftUI

/// Backs the Sources settings screen: lists registered sources and manages
/// installation, configuration and removal of third-party providers.
@MainActor
@Observable
final class SourcesModel {
    private let services: Services

    var sources: [SourceInfo] = []
    var installedManifests: [SourceManifest] = []
    var errorMessage: String?
    var infoMessage: String?
    var isInstalling = false
    /// Set when the parser host is missing or unusable.
    var kotatsuUnavailableReason: String?

    init(services: Services) {
        self.services = services
    }

    var builtInSources: [SourceInfo] {
        sources.filter { $0.provider == .builtIn }
    }

    var kotatsuSources: [SourceInfo] {
        sources.filter { $0.provider == .kotatsuHost }
    }

    var installedSources: [SourceInfo] {
        sources.filter { $0.provider == .scripted }
    }

    func refresh() async {
        sources = await services.registry.all()
        installedManifests = services.installer.installedManifests()
        kotatsuUnavailableReason = services.kotatsuUnavailableReason
    }

    func setEnabled(_ isEnabled: Bool, id: String) async {
        await services.registry.setEnabled(isEnabled, id: id)
        do {
            try services.sourceStore.setEnabled(isEnabled, sourceId: id)
            errorMessage = nil
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
        await refresh()
    }

    func sourceName(for id: String) -> String {
        sources.first { $0.id == id }?.name ?? id
    }

    // MARK: - Installation

    func install(package: SourcePackage, force: Bool = false) async {
        isInstalling = true
        defer { isInstalling = false }
        do {
            try await services.installer.install(package, force: force)
            infoMessage = "Installed “\(package.manifest.name)”."
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func install(bundleAt url: URL) async {
        do {
            let package = try SourcePackageLoader.load(bundleAt: url)
            await install(package: package)
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func install(manifestURL: URL) async {
        isInstalling = true
        defer { isInstalling = false }
        do {
            let package = try await SourcePackageLoader.load(fromManifestURL: manifestURL, http: services.http)
            try await services.installer.install(package)
            infoMessage = "Installed “\(package.manifest.name)”."
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func installBundledSample() async {
        do {
            let package = try SourceInstallService.bundledSamplePackage()
            await install(package: package, force: true)
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func remove(id: String) async {
        do {
            try await services.installer.remove(id: id)
            infoMessage = "Removed “\(sourceName(for: id))”."
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    /// Rebuilds the provider with new settings from the configuration sheet.
    func applyConfiguration(id: String, values: [String: String]) async {
        do {
            try await services.installer.updateConfiguration(id: id, config: values)
            infoMessage = "Saved settings for “\(sourceName(for: id))”."
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func configuration(for manifest: SourceManifest) -> [String: String] {
        let stored = try? services.sourceStore.preferences(for: manifest.id)?.config
        return services.installer.configuration(for: manifest, stored: stored)
    }

    func manifest(for source: SourceInfo) -> SourceManifest? {
        installedManifests.first { $0.id == source.id }
    }
}
