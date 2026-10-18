import Foundation

/// Marks a URL whose bytes must be fetched by a provider host rather than by the
/// app's own HTTP client.
///
/// This exists because some sources only serve images correctly when the request
/// carries the source's `Referer`, cookies and interceptors — fetching the raw CDN
/// URL from the app is answered with 403. Encoding the need in the URL (rather than
/// a field on `Page`) means covers get the same treatment as pages for free.
///
/// Shape: `kotatsu-image://parser/<SOURCE_KEY>/<base64url(remoteURL)>`
/// The source key lives in the path, not the host, because `URL` lowercases hosts
/// and provider keys are upper case.
nonisolated enum HostImageURL {
    static let scheme = "kotatsu-image"
    private static let markerHost = "parser"

    static func make(sourceKey: String, remote: URL) -> URL? {
        guard !sourceKey.isEmpty, let encoded = encode(remote.absoluteString) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = markerHost
        components.path = "/\(sourceKey)/\(encoded)"
        return components.url
    }

    static func parse(_ url: URL) -> (sourceKey: String, remote: URL)? {
        guard url.scheme == scheme else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2 else { return nil }
        guard let remoteString = decode(parts[1]), let remote = URL(string: remoteString) else { return nil }
        return (parts[0], remote)
    }

    static func isHostImage(_ url: URL) -> Bool {
        url.scheme == scheme
    }

    // MARK: - base64url

    private static func encode(_ value: String) -> String? {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decode(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Materialises an image through a provider host and returns a readable local file.
nonisolated protocol HostImageResolving: Sendable {
    /// - Returns: a file URL the caller can read.
    func localImageFile(sourceKey: String, remote: URL) async throws -> URL
    func imageData(sourceKey: String, remote: URL) async throws -> Data
}

/// Resolves images through the Kotatsu parser host, which applies each parser's own
/// headers, cookies and image descrambling.
actor KotatsuImageResolver: HostImageResolving {
    private let host: KotatsuHostProcess

    init(host: KotatsuHostProcess) {
        self.host = host
    }

    func localImageFile(sourceKey: String, remote: URL) async throws -> URL {
        let response = try await host.call(
            "image",
            parameters: ImageRequest(key: sourceKey, url: remote.absoluteString),
            as: ImageResponse.self,
            timeout: .seconds(120)
        )
        let file = URL(fileURLWithPath: response.path)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw MangaSourceError.provider("The parser host did not produce an image file.")
        }
        return file
    }

    func imageData(sourceKey: String, remote: URL) async throws -> Data {
        try Data(contentsOf: try await localImageFile(sourceKey: sourceKey, remote: remote))
    }

    nonisolated struct ImageRequest: Encodable, Sendable {
        let key: String
        let url: String
    }

    nonisolated struct ImageResponse: Decodable, Sendable {
        let path: String
        let bytes: Int
        let contentType: String?
    }
}
