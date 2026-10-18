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

    var pinnedCount: Int {
        sources.filter(\.isPinned).count
    }

    /// Sources shown in Settings → Sources → See Sources. The disabled toggle
    /// chooses the range the search runs over; pinned sources float to the top.
    func visibleSources(includeDisabled: Bool, query: String) -> [SourceInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sources
            .filter { includeDisabled || $0.isEnabled }
            .filter { source in
                guard !trimmed.isEmpty else { return true }
                return source.name.localizedCaseInsensitiveContains(trimmed)
                    || source.id.localizedCaseInsensitiveContains(trimmed)
                    || source.language.localizedCaseInsensitiveContains(trimmed)
                    || source.contentType.localizedCaseInsensitiveContains(trimmed)
                    || source.provider.rawValue.localizedCaseInsensitiveContains(trimmed)
            }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
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

    /// Keeps the parser sources for the selected locales and content types
    /// enabled, and switches the rest off. MangaDex is native and
    /// language-independent, so it is left to the registry.
    func applySourceSelection(
        languages: Set<String>,
        contentTypes: Set<SourceContentType>
    ) async {
        await refresh()
        guard !languages.isEmpty, !contentTypes.isEmpty else { return }

        let kotatsu = sources.filter { $0.provider == .kotatsuHost }
        let matching = Set(kotatsu.filter { source in
            Self.sourceLanguage(source.language, matchesAny: languages)
                && contentTypes.contains(
                    SourceContentType.category(for: source.contentType)
                )
        }.map(\.id))
        let others = Set(kotatsu.map(\.id)).subtracting(matching)

        for id in matching {
            await services.registry.setEnabled(true, id: id)
        }
        for id in others {
            await services.registry.setEnabled(false, id: id)
        }

        do {
            try services.sourceStore.setEnabled(true, sourceIds: matching)
            try services.sourceStore.setEnabled(false, sourceIds: others)
            errorMessage = nil
        } catch {
            errorMessage = userFacingMessage(for: error)
        }

        await refresh()
    }

    func setPinned(_ isPinned: Bool, id: String) async {
        await services.registry.setPinned(isPinned, id: id)
        do {
            try services.sourceStore.setPinned(isPinned, sourceId: id)
            errorMessage = nil
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
        await refresh()
    }

    /// Compatibility wrapper for callers that only care about language.
    func applySourceLanguage(_ language: String) async {
        await applySourceSelection(
            languages: [language],
            contentTypes: Set(SourceContentType.allCases)
        )
    }

    static func sourceLanguage(
        _ source: String,
        matchesAny languages: Set<String>
    ) -> Bool {
        guard !languages.isEmpty else { return false }
        return languages.contains { sourceLanguage(source, matches: $0) }
    }

    static func sourceLanguage(_ source: String, matches language: String) -> Bool {
        let normalizedSource = source.lowercased()
        let normalizedLanguage = language.lowercased()

        if normalizedSource == "multi"
            || normalizedLanguage == "multi"
            || normalizedSource == "all" {
            return true
        }
        if normalizedSource == normalizedLanguage {
            return true
        }

        // Locale tags commonly arrive as `pt-BR` or `zh-Hans`; match at the
        // language level when either side is the shorter tag.
        return normalizedSource.hasPrefix(normalizedLanguage + "-")
            || normalizedLanguage.hasPrefix(normalizedSource + "-")
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
