import Foundation
import Testing
@testable import Azumanga

@Suite("SourceManifest")
struct SourceManifestTests {
    private func manifest(
        apiVersion: Int = 1,
        id: String = "com.example.demo",
        name: String = "Demo",
        version: String = "1.0.0",
        main: String = "index.js",
        language: String = "en",
        allowedHosts: [String] = ["api.example.com"],
        capabilities: [SourceCapability] = [.search, .popular],
        config: [SourceManifest.ConfigField] = []
    ) -> SourceManifest {
        SourceManifest(
            apiVersion: apiVersion,
            id: id,
            name: name,
            version: version,
            main: main,
            language: language,
            allowedHosts: allowedHosts,
            capabilities: capabilities,
            config: config
        )
    }

    @Test("A well-formed manifest validates")
    func validManifest() throws {
        try manifest().validate()
    }

    @Test("Unknown API versions are refused")
    func apiVersion() {
        #expect(throws: SourceManifestError.unsupportedAPIVersion(2)) {
            try manifest(apiVersion: 2).validate()
        }
    }

    @Test("Identifiers cannot escape the install directory or omit a domain")
    func identifierValidation() {
        let bad = ["ab", "nodot", "com/example", "com..example", ".com.example", "com.example.", "com example", "com.example/../evil"]
        for id in bad {
            #expect(throws: SourceManifestError.self, "expected “\(id)” to be rejected") {
                try manifest(id: id).validate()
            }
        }
        #expect(throws: Never.self) {
            try manifest(id: "com.example.manga-dex_1").validate()
        }
    }

    @Test("Versions must look numeric")
    func versionValidation() {
        for version in ["1.0.0", "1.0", "12.34.56"] {
            #expect(throws: Never.self) { try manifest(version: version).validate() }
        }
        for version in ["1", "v1.0", "1.0.0-beta", "1..0", "1.0.0.0"] {
            #expect(throws: SourceManifestError.self, "expected “\(version)” to be rejected") {
                try manifest(version: version).validate()
            }
        }
    }

    @Test("The script must be a bare .js filename")
    func scriptValidation() {
        for main in ["../evil.js", "sub/index.js", "/etc/passwd.js", "index.txt", ""] {
            #expect(throws: SourceManifestError.self, "expected “\(main)” to be rejected") {
                try manifest(main: main).validate()
            }
        }
        #expect(throws: Never.self) { try manifest(main: "provider.js").validate() }
    }

    @Test("Hosts must be declared, and wildcards are not the whole world")
    func hostValidation() {
        for hosts in [[], ["*"], ["has space.com"], ["http://example.com"]] {
            #expect(throws: SourceManifestError.self) {
                try manifest(allowedHosts: hosts).validate()
            }
        }
    }

    @Test("Host matching supports exact, subdomain and wildcard patterns")
    func hostMatching() {
        let manifest = manifest(allowedHosts: ["example.com", "*.mangadex.network"])
        #expect(manifest.allows(host: "example.com"))
        #expect(manifest.allows(host: "api.example.com"))
        #expect(manifest.allows(host: "node-1.mangadex.network"))
        #expect(manifest.allows(host: "MANGADEX.NETWORK"))
        #expect(!manifest.allows(host: "notexample.com"))
        #expect(!manifest.allows(host: "evil.test"))
        // A wildcard pattern must not match the bare domain's sibling.
        #expect(!manifest.allows(host: "example.org"))
    }

    @Test("Configuration keys are unique and selects need options")
    func configurationValidation() throws {
        let duplicate = [
            SourceManifest.ConfigField(key: "quality", label: "Quality", type: .text, options: nil, defaultValue: nil),
            SourceManifest.ConfigField(key: "quality", label: "Again", type: .text, options: nil, defaultValue: nil),
        ]
        #expect(throws: SourceManifestError.self) { try manifest(config: duplicate).validate() }

        let emptySelect = [SourceManifest.ConfigField(key: "quality", label: "Quality", type: .select, options: [], defaultValue: nil)]
        #expect(throws: SourceManifestError.self) { try manifest(config: emptySelect).validate() }

        let valid = [SourceManifest.ConfigField(key: "quality", label: "Quality", type: .select, options: ["a", "b"], defaultValue: "b")]
        try manifest(config: valid).validate()
    }

    @Test("Defaults are derived from the declared configuration")
    func derivedDefaults() {
        let manifest = manifest(config: [
            SourceManifest.ConfigField(key: "quality", label: "Quality", type: .select, options: ["data-saver", "data"], defaultValue: nil),
            SourceManifest.ConfigField(key: "adult", label: "Adult", type: .toggle, options: nil, defaultValue: nil),
            SourceManifest.ConfigField(key: "note", label: "Note", type: .text, options: nil, defaultValue: "hello"),
        ])
        let defaults = manifest.defaultConfiguration
        #expect(defaults["quality"] == "data-saver")
        #expect(defaults["adult"] == "false")
        #expect(defaults["note"] == "hello")
    }

    @Test("Decoding rejects a manifest missing required fields")
    func decoding() throws {
        let json = #"{"apiVersion":1,"id":"com.example.demo","name":"Demo","version":"1.0.0","main":"index.js","language":"en","allowedHosts":["a.com"],"capabilities":["search"],"config":[]}"#
        let decoded = try SourceManifest.decodeAndValidate(Data(json.utf8))
        #expect(decoded.id == "com.example.demo")

        #expect(throws: SourceManifestError.self) {
            try SourceManifest.decodeAndValidate(Data(#"{"apiVersion":1}"#.utf8))
        }
        #expect(throws: SourceManifestError.self) {
            try SourceManifest.decodeAndValidate(Data("not json".utf8))
        }
    }
}
