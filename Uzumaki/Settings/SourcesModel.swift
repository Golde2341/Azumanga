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
    /// Last known health per source id.
    var healthBySource: [String: SourceHealthSnapshot] = [:]

    init(services: Services) {
        self.services = services
    }

    var builtInSources: [SourceInfo] {
        sources.filter { $0.provider == .builtIn }
    }

    /// Every Kotatsu source, including ones the library flags as broken (those are
    /// shown, but switched off).
    var kotatsuSources: [SourceInfo] {
        sources
            .filter { $0.provider == .kotatsuHost }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var installedSources: [SourceInfo] {
        sources.filter { $0.provider == .scripted }
    }

    /// Kotatsu sources worth showing: enabled, known-good, or never checked.
    /// Broken ones are hidden unless the user asks for everything.
    func kotatsuSources(showAll: Bool) -> [SourceInfo] {
        kotatsuSources.filter { source in
            if showAll { return true }
            if source.isEnabled { return true }
            return healthBySource[source.id]?.health == .working
        }
    }

    var kotatsuWorkingCount: Int {
        kotatsuSources.count { healthBySource[$0.id]?.health == .working }
    }

    var kotatsuEnabledCount: Int {
        kotatsuSources.count { $0.isEnabled }
    }

    func health(of source: SourceInfo) -> SourceHealth {
        healthBySource[source.id]?.health ?? .untested
    }

    func healthDetail(of source: SourceInfo) -> String? {
        healthBySource[source.id]?.detail
    }

    /// Called by the health checker as it works, so the list updates live.
    func applyHealth(_ snapshot: SourceHealthSnapshot, isEnabled: Bool, sourceId: String) {
        healthBySource[sourceId] = snapshot
        if let index = sources.firstIndex(where: { $0.id == sourceId }) {
            sources[index].isEnabled = isEnabled
        }
    }

    func refresh() async {
        sources = await services.registry.all()
        installedManifests = services.installer.installedManifests()
        kotatsuUnavailableReason = services.kotatsuUnavailableReason
        healthBySource = services.healthSnapshots()
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
