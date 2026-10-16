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
        config: [String: String]? = nil
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
        if context.hasChanges { try context.save() }
        return record
    }

    func setEnabled(_ enabled: Bool, sourceId: String) throws {
        guard let record = try preferences(for: sourceId) else { return }
        record.isEnabled = enabled
        record.updatedAt = Date()
        if context.hasChanges { try context.save() }
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
}
