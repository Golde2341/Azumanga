import Foundation
import JavaScriptCore

/// A box that lets a non-`Sendable` value cross a `@Sendable` boundary when the
/// code guarantees it is only touched on one serial queue (the JS host queue).
nonisolated final class UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// The native surface exposed to provider JavaScript: `http`, `console`, `utils`
/// and `config`. This is the entire sandbox boundary — provider code cannot reach
/// anything else in the app. Host access is restricted to the hosts declared in
/// the manifest, response size is capped, and every request goes through the
/// shared `HTTPClient` (so rate limiting and retries still apply).
nonisolated final class JSContextBridge: @unchecked Sendable {
    private let http: HTTPClient
    private let allowedHosts: [String]
    private let queue: DispatchQueue
    private let log: @Sendable (String) -> Void
    private let maxResponseBytes: Int
    private weak var context: JSContext?

    init(
        http: HTTPClient,
        allowedHosts: [String],
        queue: DispatchQueue,
        maxResponseBytes: Int = 32 * 1024 * 1024,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.http = http
        self.allowedHosts = allowedHosts
        self.queue = queue
        self.maxResponseBytes = maxResponseBytes
        self.log = log
    }

    /// Installs the bridge globals. Must be called on the host queue.
    func install(into context: JSContext, configuration: [String: String]) {
        self.context = context
        installConsole(into: context)
        installUtils(into: context)
        installHTTP(into: context)
        context.setObject(configuration, forKeyedSubscript: "config" as NSString)
    }

    // MARK: - console

    private func installConsole(into context: JSContext) {
        let log = log
        let console = JSValue(newObjectIn: context)!
        let sink: @convention(block) (JSValue?) -> Void = { value in
            log(value?.toString() ?? "undefined")
        }
        console.setObject(sink, forKeyedSubscript: "log" as NSString)
        console.setObject(sink, forKeyedSubscript: "warn" as NSString)
        console.setObject(sink, forKeyedSubscript: "error" as NSString)
        console.setObject(sink, forKeyedSubscript: "info" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    // MARK: - utils

    private func installUtils(into context: JSContext) {
        let utils = JSValue(newObjectIn: context)!

        let decode: @convention(block) (String?) -> String = { text in
            guard let text, let data = Data(base64Encoded: text) else { return "" }
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
        }
        let encode: @convention(block) (String?) -> String = { text in
            Data((text ?? "").utf8).base64EncodedString()
        }
        let sleep: @convention(block) (Double) -> JSValue = { [weak self] milliseconds in
            guard let self, let context = self.context else { return JSValue() }
            return JSValue(newPromiseIn: context) { resolve, _ in
                guard let resolve else { return }
                let box = UncheckedBox(resolve)
                let seconds = min(max(milliseconds, 0), 30_000) / 1000
                self.queue.asyncAfter(deadline: .now() + seconds) {
                    box.value.call(withArguments: [])
                }
            } ?? JSValue()
        }

        utils.setObject(decode, forKeyedSubscript: "base64Decode" as NSString)
        utils.setObject(encode, forKeyedSubscript: "base64Encode" as NSString)
        utils.setObject(sleep, forKeyedSubscript: "sleep" as NSString)
        context.setObject(utils, forKeyedSubscript: "utils" as NSString)
    }

    // MARK: - http

    private func installHTTP(into context: JSContext) {
        let http = JSValue(newObjectIn: context)!

        let get: @convention(block) (JSValue?, JSValue?) -> JSValue = { [weak self] urlValue, headersValue in
            self?.requestPromise(method: "GET", url: urlValue?.toString(), headers: headersValue, body: nil, contentType: nil)
                ?? JSValue()
        }

        let post: @convention(block) (JSValue?, JSValue?, JSValue?, JSValue?) -> JSValue = { [weak self] urlValue, bodyValue, contentTypeValue, headersValue in
            self?.requestPromise(
                method: "POST",
                url: urlValue?.toString(),
                headers: headersValue,
                body: bodyValue?.toString(),
                contentType: contentTypeValue?.toString()
            ) ?? JSValue()
        }

        http.setObject(get, forKeyedSubscript: "get" as NSString)
        http.setObject(post, forKeyedSubscript: "post" as NSString)
        context.setObject(http, forKeyedSubscript: "http" as NSString)
    }

    private func requestPromise(
        method: String,
        url: String?,
        headers: JSValue?,
        body: String?,
        contentType: String?
    ) -> JSValue {
        guard let context else { return JSValue() }

        return JSValue(newPromiseIn: context) { [weak self] resolve, reject in
            guard let self, let resolve, let reject else { return }
            let resolveBox = UncheckedBox(resolve)
            let rejectBox = UncheckedBox(reject)

            func fail(_ message: String) {
                self.queue.async { rejectBox.value.call(withArguments: [message]) }
            }

            guard let url, let requestURL = URL(string: url) else {
                fail("Invalid URL: \(url ?? "nil")")
                return
            }
            guard let host = requestURL.host else {
                fail("URL has no host: \(url)")
                return
            }
            guard SourceManifest.host(host, matchesAnyOf: self.allowedHosts) else {
                self.log("Blocked request to undeclared host: \(host)")
                fail(SourceManifestError.hostNotAllowed(host).localizedDescription)
                return
            }

            let headerDictionary = Self.stringDictionary(headers)
            let byteLimit = self.maxResponseBytes

            Task { [weak self] in
                guard let self else { return }
                do {
                    var request = URLRequest(url: requestURL)
                    request.httpMethod = method
                    for (key, value) in headerDictionary {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                    if let body {
                        request.httpBody = Data(body.utf8)
                        request.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
                    }

                    let response = try await self.http.data(for: request, allowRetry: true)
                    guard response.data.count <= byteLimit else {
                        throw MangaSourceError.provider("Response exceeded \(byteLimit) bytes")
                    }

                    // Sendable payload only; the JS object is built on the host queue.
                    let payload = ResponsePayload(
                        status: response.statusCode,
                        headers: response.headers,
                        url: requestURL.absoluteString,
                        data: response.data
                    )
                    self.queue.async {
                        resolveBox.value.call(withArguments: [payload.asJavaScriptObject()])
                    }
                } catch {
                    self.queue.async {
                        rejectBox.value.call(withArguments: [userFacingMessage(for: error)])
                    }
                }
            }
        } ?? JSValue()
    }

    private static func stringDictionary(_ value: JSValue?) -> [String: String] {
        guard let value, value.isObject else { return [:] }
        guard let dictionary = value.toDictionary() as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, raw) in dictionary {
            result[key] = (raw as? String) ?? String(describing: raw)
        }
        return result
    }
}

/// Sendable snapshot of an HTTP reply, converted to a JS value on the JS queue.
private struct ResponsePayload: Sendable {
    let status: Int
    let headers: [String: String]
    let url: String
    let data: Data

    func asJavaScriptObject() -> [String: Any] {
        [
            "status": status,
            "headers": headers,
            "url": url,
            "bytes": data.count,
            "body": Self.parse(data),
        ]
    }

    /// JSON responses arrive as objects; anything else is passed through as text.
    private static func parse(_ data: Data) -> Any {
        if data.isEmpty { return "" }
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return object
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
