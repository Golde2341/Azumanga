import Foundation
import Testing
@testable import Azumanga

@Suite("InstalledSourceStore")
struct InstalledSourceStoreTests {
    private func makeStore() -> InstalledSourceStore {
        InstalledSourceStore(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("azumanga-providers-\(UUID().uuidString)", isDirectory: true)
        )
    }

    private func package(
        id: String = "com.example.demo",
        version: String = "1.0.0",
        script: String = "globalThis.Source = {};"
    ) -> SourcePackage {
        SourcePackage(
            manifest: SourceManifest(
                id: id,
                name: "Demo",
                version: version,
                allowedHosts: ["api.example.com"],
                capabilities: [.search]
            ),
            script: script
        )
    }

    @Test("Installing writes a loadable provider")
    func installAndLoad() throws {
        let store = makeStore()
        let installed = try store.install(package())

        #expect(installed.manifest.id == "com.example.demo")
        #expect(store.isInstalled("com.example.demo"))
        #expect(store.installedSourceIDs() == ["com.example.demo"])

        let reloaded = try store.load(id: "com.example.demo")
        #expect(reloaded.manifest.version == "1.0.0")
        #expect(reloaded.script.contains("globalThis.Source"))
        #expect(FileManager.default.fileExists(atPath: reloaded.directory.appendingPathComponent("manifest.json").path))
    }

    @Test("A newer version replaces the installed one")
    func upgrade() throws {
        let store = makeStore()
        try store.install(package(version: "1.0.0"))
        let upgraded = try store.install(package(version: "1.1.0"))

        #expect(upgraded.manifest.version == "1.1.0")
        #expect(try store.load(id: "com.example.demo").manifest.version == "1.1.0")
    }

    @Test("A downgrade is refused unless forced")
    func downgrade() throws {
        let store = makeStore()
        try store.install(package(version: "2.0.0"))

        #expect(throws: SourceManifestError.alreadyInstalledNewer(found: "1.0.0", existing: "2.0.0")) {
            try store.install(package(version: "1.0.0"))
        }
        let forced = try store.install(package(version: "1.0.0"), force: true)
        #expect(forced.manifest.version == "1.0.0")
    }

    @Test("An empty script is rejected")
    func emptyScript() {
        let store = makeStore()
        #expect(throws: SourceManifestError.missingScript) {
            try store.install(package(script: "   \n"))
        }
    }

    @Test("Removing deletes the provider")
    func remove() throws {
        let store = makeStore()
        try store.install(package())
        try store.remove(id: "com.example.demo")

        #expect(!store.isInstalled("com.example.demo"))
        #expect(throws: SourceManifestError.notInstalled("com.example.demo")) {
            try store.remove(id: "com.example.demo")
        }
    }

    @Test("Corrupt providers are reported, not loaded")
    func corruptProvider() throws {
        let store = makeStore()
        try store.install(package())

        // Corrupt the stored manifest on disk.
        let manifestURL = store.directory(for: "com.example.demo").appendingPathComponent("manifest.json")
        try Data("{ not json".utf8).write(to: manifestURL)

        let loaded = store.loadAll()
        #expect(loaded.sources.isEmpty)
        #expect(loaded.failures["com.example.demo"] != nil)
    }

    @Test("Identifiers that could escape the install root are refused")
    func pathTraversal() throws {
        let store = makeStore()
        #expect(!InstalledSourceStore.isSafeIdentifier("../evil"))
        #expect(!InstalledSourceStore.isSafeIdentifier("a/b"))
        #expect(!InstalledSourceStore.isSafeIdentifier(""))
        #expect(InstalledSourceStore.isSafeIdentifier("com.example.demo"))

        #expect(throws: SourceManifestError.notInstalled("../evil")) {
            try store.remove(id: "../evil")
        }
    }

    @Test("Version comparison is numeric, not lexical")
    func versionComparison() {
        #expect(InstalledSourceStore.compareVersions("1.0.0", "1.0.0") == 0)
        #expect(InstalledSourceStore.compareVersions("1.10.0", "1.9.0") == 1)
        #expect(InstalledSourceStore.compareVersions("1.0", "1.0.1") == -1)
        #expect(InstalledSourceStore.compareVersions("2.0", "1.9.9") == 1)
    }

    @Test("Bundle files load and validate")
    func bundleLoading() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("azumanga-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = SourcePackage.Bundle(
            manifest: SourceManifest(id: "com.example.demo", name: "Demo", version: "1.0.0", allowedHosts: ["a.com"]),
            script: "globalThis.Source = {};"
        )
        let url = directory.appendingPathComponent("demo.uzsource.json")
        try JSONEncoder().encode(bundle).write(to: url)

        let loaded = try SourcePackageLoader.load(bundleAt: url)
        #expect(loaded.manifest.id == "com.example.demo")
        #expect(loaded.script.contains("Source"))
    }

    @Test("Malformed bundle files are rejected")
    func malformedBundle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("azumanga-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("bad.json")
        try Data(#"{"manifest":{"apiVersion":9}}"#.utf8).write(to: url)
        #expect(throws: SourceManifestError.self) {
            try SourcePackageLoader.load(bundleAt: url)
        }
    }
}
