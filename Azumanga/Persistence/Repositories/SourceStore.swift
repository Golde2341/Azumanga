import Foundation
import SwiftData

/// Persists per-source enablement, version and configuration for both built-in
/// and installed sources.
@MainActor
final class SourceStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func all() throws -> [SourcePreferences] {
        try context.fetch(
            FetchDescriptor<SourcePreferences>(sortBy: [SortDescriptor(\SourcePreferences.name, order: .forward)])
        )
    }

    func preferences(for sourceId: String) throws -> SourcePreferences? {
        var descriptor = FetchDescriptor<SourcePreferences>(predicate: #Predicate { $0.sourceId == sourceId })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Inserts or updates the record for a source, preserving existing user
    /// configuration unless a new one is supplied.
    @discardableResult
    func upsert(
        sourceId: String,
        name: String,
        version: String,
        isBuiltIn: Bool,
        isEnabled: Bool? = nil,
        config: [String: String]? = nil,
        save: Bool = true
    ) throws -> SourcePreferences {
        let record: SourcePreferences
        if let existing = try preferences(for: sourceId) {
            record = existing
        } else {
            record = SourcePreferences(sourceId: sourceId, name: name, version: version, isBuiltIn: isBuiltIn)
            context.insert(record)
        }
        record.name = name
        record.version = version
        record.isBuiltIn = isBuiltIn
        if let isEnabled { record.isEnabled = isEnabled }
        if let config { record.config = config }
        record.updatedAt = Date()
        // Bulk registration inserts many rows; saving each one would be needlessly slow.
        if save, context.hasChanges { try context.save() }
        return record
    }

    func save() throws {
        if context.hasChanges { try context.save() }
    }

    /// Inserts a source row without looking for an existing one first.
    ///
    /// `upsert` fetches before writing, which is fine for one source but quadratic
    /// across the ~1370 Kotatsu sources — bulk registration uses this instead, after
    /// establishing which ids are genuinely new.
    @discardableResult
    func insert(
        sourceId: String,
        name: String,
        version: String,
        isBuiltIn: Bool,
        isEnabled: Bool,
        health: SourceHealth,
        healthDetail: String?
    ) -> SourcePreferences {
        let record = SourcePreferences(
            sourceId: sourceId,
            name: name,
            version: version,
            isBuiltIn: isBuiltIn,
            isEnabled: isEnabled,
            health: health,
            healthDetail: healthDetail
        )
        context.insert(record)
        return record
    }

    func setEnabled(_ enabled: Bool, sourceId: String) throws {
        guard let record = try preferences(for: sourceId) else { return }
        record.isEnabled = enabled
        record.updatedAt = Date()
        if context.hasChanges { try context.save() }
    }

    func setEnabled(_ enabled: Bool, sourceIds: Set<String>) throws {
        guard !sourceIds.isEmpty else { return }
        for sourceId in sourceIds {
            guard let record = try preferences(for: sourceId) else { continue }
            record.isEnabled = enabled
            record.updatedAt = Date()
        }
        if context.hasChanges { try context.save() }
    }

    func setPinned(_ isPinned: Bool, sourceId: String) throws {
        guard let record = try preferences(for: sourceId) else { return }
        record.isPinned = isPinned
        record.updatedAt = Date()
        if context.hasChanges { try context.save() }
    }

    func pinnedSourceIds() throws -> Set<String> {
        let descriptor = FetchDescriptor<SourcePreferences>(predicate: #Predicate { $0.isPinned })
        return Set(try context.fetch(descriptor).map(\.sourceId))
    }

    func setConfig(_ config: [String: String], sourceId: String) throws {
        guard let record = try preferences(for: sourceId) else { return }
        record.config = config
        record.updatedAt = Date()
        if context.hasChanges { try context.save() }
    }

    func remove(sourceId: String) throws {
        guard let record = try preferences(for: sourceId) else { return }
        context.delete(record)
        if context.hasChanges { try context.save() }
    }

    func enabledSourceIds() throws -> Set<String> {
        let descriptor = FetchDescriptor<SourcePreferences>(predicate: #Predicate { $0.isEnabled })
        return Set(try context.fetch(descriptor).map(\.sourceId))
    }

    // MARK: - Health

    /// Records the outcome of a health check, and switches off a source that failed.
    func recordHealth(
        _ health: SourceHealth,
        detail: String?,
        sourceId: String,
        disableOnFailure: Bool = true
    ) throws {
        guard let record = try preferences(for: sourceId) else { return }
        record.health = health
        record.healthDetail = detail
        record.lastCheckedAt = Date()
        if health == .failing && disableOnFailure {
            record.isEnabled = false
        }
        record.updatedAt = Date()
        if context.hasChanges { try context.save() }
    }

    func healthSnapshot() throws -> [String: SourceHealthSnapshot] {
        var result: [String: SourceHealthSnapshot] = [:]
        for record in try all() {
            result[record.sourceId] = SourceHealthSnapshot(
                health: record.health,
                detail: record.healthDetail,
                checkedAt: record.lastCheckedAt
            )
        }
        return result
    }
}

/// A source's last known health, for display.
nonisolated struct SourceHealthSnapshot: Sendable, Hashable {
    var health: SourceHealth
    var detail: String?
    var checkedAt: Date?
}
