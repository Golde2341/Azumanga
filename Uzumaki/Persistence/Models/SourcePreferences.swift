import Foundation
import SwiftData

/// Persisted configuration for a source — built-in or installed. Mirrors the
/// manifest so the registry can restore state without re-scanning disk.
@Model
final class SourcePreferences {
    var sourceId: String
    var name: String
    var version: String
    var isBuiltIn: Bool
    var isEnabled: Bool
    /// JSON-encoded `[String: String]` of user-supplied configuration values.
    var configJSON: String
    var installedAt: Date
    var updatedAt: Date

    init(
        sourceId: String,
        name: String,
        version: String,
        isBuiltIn: Bool,
        isEnabled: Bool = true,
        config: [String: String] = [:],
        installedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.sourceId = sourceId
        self.name = name
        self.version = version
        self.isBuiltIn = isBuiltIn
        self.isEnabled = isEnabled
        self.configJSON = Self.encode(config: config)
        self.installedAt = installedAt
        self.updatedAt = updatedAt
    }

    var config: [String: String] {
        get {
            guard let data = configJSON.data(using: .utf8),
                  let values = try? JSONDecoder().decode([String: String].self, from: data)
            else { return [:] }
            return values
        }
        set { configJSON = Self.encode(config: newValue) }
    }

    private static func encode(config: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(config),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}
