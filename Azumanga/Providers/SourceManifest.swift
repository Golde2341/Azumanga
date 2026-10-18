import Foundation

/// Errors raised while validating or installing an untrusted provider package.
nonisolated enum SourceManifestError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedAPIVersion(Int)
    case invalidField(String, reason: String)
    case missingScript
    case hostNotAllowed(String)
    case alreadyInstalledNewer(found: String, existing: String)
    case notInstalled(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedAPIVersion(let version):
            "This provider needs provider API v\(version), which this version of Azumanga does not support."
        case .invalidField(let field, let reason):
            "Invalid manifest field “\(field)”: \(reason)"
        case .missingScript:
            "The provider package did not include a script."
        case .hostNotAllowed(let host):
            "The provider tried to reach “\(host)”, which is not listed in its allowed hosts."
        case .alreadyInstalledNewer(let found, let existing):
            "A newer version (\(existing)) is already installed; refusing to replace it with \(found)."
        case .notInstalled(let id):
            "Provider “\(id)” is not installed."
        }
    }
}

/// A declarative description of an installable provider. Everything here is
/// untrusted input read from disk or the network, so it is validated before use.
nonisolated struct SourceManifest: Codable, Sendable, Hashable, Identifiable {
    /// Provider API revision this app implements.
    static let currentAPIVersion = 1

    var apiVersion: Int
    var id: String
    var name: String
    var version: String
    /// Script filename, relative to the provider directory (no path components).
    var main: String
    var language: String
    /// Hosts the provider is permitted to contact. `*.example.com` allows subdomains.
    var allowedHosts: [String]
    var capabilities: [SourceCapability]
    var config: [ConfigField]
    var icon: String?
    var homepage: String?

    struct ConfigField: Codable, Sendable, Hashable, Identifiable {
        enum Kind: String, Codable, Sendable {
            case text
            case toggle
            case select
        }

        var key: String
        var label: String
        var type: Kind
        var options: [String]?
        var defaultValue: String?

        var id: String { key }

        enum CodingKeys: String, CodingKey {
            case key, label, type, options
            case defaultValue = "default"
        }
    }

    enum CodingKeys: String, CodingKey {
        case apiVersion, id, name, version, main, language, allowedHosts, capabilities, config, icon, homepage
    }

    init(
        apiVersion: Int = SourceManifest.currentAPIVersion,
        id: String,
        name: String,
        version: String,
        main: String = "index.js",
        language: String = "en",
        allowedHosts: [String],
        capabilities: [SourceCapability] = [.search, .popular, .latest, .filters, .chapters, .pages],
        config: [ConfigField] = [],
        icon: String? = nil,
        homepage: String? = nil
    ) {
        self.apiVersion = apiVersion
        self.id = id
        self.name = name
        self.version = version
        self.main = main
        self.language = language
        self.allowedHosts = allowedHosts
        self.capabilities = capabilities
        self.config = config
        self.icon = icon
        self.homepage = homepage
    }

    /// Decodes from JSON and validates in one step — untrusted input never
    /// reaches the rest of the app without passing through here.
    static func decodeAndValidate(_ data: Data) throws -> SourceManifest {
        let manifest: SourceManifest
        do {
            manifest = try JSONDecoder().decode(SourceManifest.self, from: data)
        } catch {
            throw SourceManifestError.invalidField("manifest", reason: "could not be parsed as JSON")
        }
        try manifest.validate()
        return manifest
    }

    func validate() throws {
        guard apiVersion == Self.currentAPIVersion else {
            throw SourceManifestError.unsupportedAPIVersion(apiVersion)
        }
        guard (3...128).contains(id.count),
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }),
              id.contains("."),
              !id.hasPrefix("."), !id.hasSuffix("."), !id.contains("..")
        else {
            throw SourceManifestError.invalidField("id", reason: "must be a reverse-DNS identifier using letters, digits, “.”, “-” or “_”")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 128 else {
            throw SourceManifestError.invalidField("name", reason: "must be 1–128 characters")
        }
        guard Self.isSemanticVersion(version) else {
            throw SourceManifestError.invalidField("version", reason: "must look like 1.2 or 1.2.3")
        }
        let trimmedMain = main.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMain.isEmpty,
              !trimmedMain.contains("/"),
              !trimmedMain.contains("\\"),
              !trimmedMain.contains(".."),
              trimmedMain.hasSuffix(".js")
        else {
            throw SourceManifestError.invalidField("main", reason: "must be a bare JavaScript filename in the provider directory")
        }
        guard (2...12).contains(language.count) else {
            throw SourceManifestError.invalidField("language", reason: "must be a short language tag such as “en”")
        }
        let hosts = allowedHosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard !hosts.isEmpty else {
            throw SourceManifestError.invalidField("allowedHosts", reason: "providers must declare the hosts they contact")
        }
        for host in hosts where host.isEmpty || host == "*" || host.contains("/") || host.contains(" ") {
            throw SourceManifestError.invalidField("allowedHosts", reason: "“\(host)” is not a valid host pattern")
        }
        var seenConfigKeys = Set<String>()
        for field in config {
            guard !field.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SourceManifestError.invalidField("config", reason: "configuration keys may not be empty")
            }
            guard seenConfigKeys.insert(field.key).inserted else {
                throw SourceManifestError.invalidField("config", reason: "duplicate key “\(field.key)”")
            }
            if field.type == .select {
                guard let options = field.options, !options.isEmpty else {
                    throw SourceManifestError.invalidField("config.\(field.key)", reason: "select fields need options")
                }
            }
        }
    }

    static func isSemanticVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber)
        }
    }

    /// Whether a host is permitted by this manifest.
    func allows(host: String) -> Bool {
        Self.host(host, matchesAnyOf: allowedHosts)
    }

    static func host(_ host: String, matchesAnyOf patterns: [String]) -> Bool {
        let candidate = host.lowercased()
        for rawPattern in patterns {
            let pattern = rawPattern.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if pattern == candidate { return true }
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(2))
                if candidate == suffix || candidate.hasSuffix("." + suffix) { return true }
            } else if candidate.hasSuffix("." + pattern) {
                return true
            }
        }
        return false
    }

    /// Default configuration values declared by the manifest.
    var defaultConfiguration: [String: String] {
        var values: [String: String] = [:]
        for field in config {
            if let defaultValue = field.defaultValue {
                values[field.key] = defaultValue
            } else if field.type == .select, let first = field.options?.first {
                values[field.key] = first
            } else if field.type == .toggle {
                values[field.key] = "false"
            } else {
                values[field.key] = ""
            }
        }
        return values
    }
}
