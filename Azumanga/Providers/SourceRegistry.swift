import Foundation

/// Runtime, provider-agnostic description of an available source.
nonisolated struct SourceInfo: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let version: String
    let language: String
    let isBuiltIn: Bool
    let provider: SourceProviderKind
    let capabilities: Set<SourceCapability>
    var isEnabled: Bool
}

/// Holds the live source instances. Views and models depend on this registry,
/// never on concrete providers, so new providers (including installed JS ones)
/// are picked up without changing UI or business logic.
actor SourceRegistry {
    private var sources: [String: any MangaSource] = [:]
    private var enabled: Set<String> = []
    private var insertionOrder: [String] = []

    init() {}

    func register(_ source: any MangaSource, isEnabled: Bool = true) {
        if sources[source.id] == nil {
            insertionOrder.append(source.id)
        }
        sources[source.id] = source
        if isEnabled {
            enabled.insert(source.id)
        } else {
            enabled.remove(source.id)
        }
    }

    func register(contentsOf newSources: [any MangaSource], enabledIds: Set<String>? = nil) {
        for source in newSources {
            let isEnabled = enabledIds.map { $0.contains(source.id) } ?? true
            register(source, isEnabled: isEnabled)
        }
    }

    @discardableResult
    func unregister(id: String) -> Bool {
        guard sources.removeValue(forKey: id) != nil else { return false }
        enabled.remove(id)
        insertionOrder.removeAll { $0 == id }
        return true
    }

    func source(id: String) -> (any MangaSource)? {
        sources[id]
    }

    func setEnabled(_ isEnabled: Bool, id: String) {
        if isEnabled {
            enabled.insert(id)
        } else {
            enabled.remove(id)
        }
    }

    func isEnabled(id: String) -> Bool {
        enabled.contains(id)
    }

    func all() -> [SourceInfo] {
        insertionOrder.compactMap { id in
            sources[id].map { info(for: $0) }
        }
    }

    func enabledSources() -> [any MangaSource] {
        insertionOrder.compactMap { id in
            guard enabled.contains(id) else { return nil }
            return sources[id]
        }
    }

    func enabledInfos() -> [SourceInfo] {
        all().filter(\.isEnabled)
    }

    func identifiers() -> [String] {
        insertionOrder
    }

    private func info(for source: any MangaSource) -> SourceInfo {
        SourceInfo(
            id: source.id,
            name: source.name,
            version: source.version,
            language: source.language,
            isBuiltIn: source.isBuiltIn,
            provider: source.providerKind,
            capabilities: source.capabilities,
            isEnabled: enabled.contains(source.id)
        )
    }
}
