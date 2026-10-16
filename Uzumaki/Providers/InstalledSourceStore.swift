import Foundation

/// A provider package ready to install: a validated manifest plus its script.
nonisolated struct SourcePackage: Sendable {
    let manifest: SourceManifest
    let script: String

    /// The one-file distribution format (`*.uzsource.json`).
    nonisolated struct Bundle: Codable, Sendable {
        var manifest: SourceManifest
        var script: String
    }
}

/// A provider that has been written to disk and can be loaded at runtime.
nonisolated struct InstalledSource: Sendable {
    let manifest: SourceManifest
    let script: String
    let directory: URL
}

/// On-disk storage for installed providers, under Application Support. Nothing
/// here is trusted: manifests are re-validated on every load.
nonisolated struct InstalledSourceStore: Sendable {
    let root: URL

    static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Uzumaki/Sources", isDirectory: true)
    }

    init(root: URL = InstalledSourceStore.defaultRoot) {
        self.root = root
    }

    func directory(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    func isInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: id).appendingPathComponent("manifest.json").path)
    }

    func installedVersions() -> [String: String] {
        var versions: [String: String] = [:]
        for id in installedSourceIDs() {
            if let source = try? load(id: id) {
                versions[id] = source.manifest.version
            }
        }
        return versions
    }

    func installedSourceIDs() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .filter(Self.isSafeIdentifier)
            .sorted()
    }

    func load(id: String) throws -> InstalledSource {
        guard Self.isSafeIdentifier(id) else {
            throw SourceManifestError.notInstalled(id)
        }
        let directory = directory(for: id)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw SourceManifestError.notInstalled(id)
        }
        let manifest = try SourceManifest.decodeAndValidate(manifestData)
        // A tampered manifest must not be able to claim another provider's identity.
        guard manifest.id == id else {
            throw SourceManifestError.invalidField("id", reason: "does not match its install directory")
        }
        guard let script = script(id: id, manifest: manifest) else {
            throw SourceManifestError.missingScript
        }
        return InstalledSource(manifest: manifest, script: script, directory: directory)
    }

    /// Loads every installed provider, skipping (and reporting) broken ones.
    func loadAll() -> (sources: [InstalledSource], failures: [String: String]) {
        var sources: [InstalledSource] = []
        var failures: [String: String] = [:]
        for id in installedSourceIDs() {
            do {
                sources.append(try load(id: id))
            } catch {
                failures[id] = userFacingMessage(for: error)
            }
        }
        return (sources, failures)
    }

    @discardableResult
    func install(_ package: SourcePackage, force: Bool = false) throws -> InstalledSource {
        try package.manifest.validate()
        guard !package.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceManifestError.missingScript
        }

        let id = package.manifest.id
        if let existing = try? load(id: id),
           !force,
           Self.compareVersions(package.manifest.version, existing.manifest.version) < 0 {
            throw SourceManifestError.alreadyInstalledNewer(found: package.manifest.version, existing: existing.manifest.version)
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        // Write to a temporary directory, then swap it in, so a failed install
        // never leaves a half-written provider behind.
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(package.manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try Data(package.script.utf8).write(to: staging.appendingPathComponent(package.manifest.main), options: .atomic)

        let destination = directory(for: id)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)

        return try load(id: id)
    }

    func remove(id: String) throws {
        guard Self.isSafeIdentifier(id) else {
            throw SourceManifestError.notInstalled(id)
        }
        let directory = directory(for: id)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw SourceManifestError.notInstalled(id)
        }
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Private

    private func script(id: String, manifest: SourceManifest) -> String? {
        let scriptURL = directory(for: id).appendingPathComponent(manifest.main)
        guard let data = try? Data(contentsOf: scriptURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Only allow directory names that cannot escape the install root.
    static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 128
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("..")
            && value != "."
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    /// Numeric component-wise comparison; returns -1, 0 or 1.
    static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}

/// Turns external inputs (a bundle file, a remote manifest) into a `SourcePackage`.
nonisolated enum SourcePackageLoader {
    static func load(bundleAt url: URL) throws -> SourcePackage {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SourceManifestError.invalidField("file", reason: "could not be read")
        }
        let bundle: SourcePackage.Bundle
        do {
            bundle = try JSONDecoder().decode(SourcePackage.Bundle.self, from: data)
        } catch {
            throw SourceManifestError.invalidField("bundle", reason: "expected { \"manifest\": …, \"script\": … }")
        }
        try bundle.manifest.validate()
        guard !bundle.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceManifestError.missingScript
        }
        return SourcePackage(manifest: bundle.manifest, script: bundle.script)
    }

    /// Fetches `manifest.json` from a URL and its `main` script beside it.
    static func load(fromManifestURL url: URL, http: HTTPClient) async throws -> SourcePackage {
        guard url.scheme == "https" else {
            throw SourceManifestError.invalidField("url", reason: "provider manifests must be fetched over HTTPS")
        }
        let manifestData: Data
        do {
            manifestData = try await http.data(for: URLRequest(url: url)).data
        } catch {
            throw SourceManifestError.invalidField("manifest", reason: userFacingMessage(for: error))
        }
        let manifest = try SourceManifest.decodeAndValidate(manifestData)

        let scriptURL = url.deletingLastPathComponent().appendingPathComponent(manifest.main)
        let scriptData: Data
        do {
            scriptData = try await http.data(for: URLRequest(url: scriptURL)).data
        } catch {
            throw SourceManifestError.missingScript
        }
        guard let script = String(data: scriptData, encoding: .utf8) else {
            throw SourceManifestError.missingScript
        }
        return SourcePackage(manifest: manifest, script: script)
    }
}
