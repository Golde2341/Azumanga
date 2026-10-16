import Foundation
import Testing
@testable import Uzumaki

nonisolated struct StubPayload: Codable, Sendable, Equatable {
    var name: String
    var count: Int
}

@Suite("HTTPClient")
struct HTTPClientTests {
    private func makeClient(attempts: Int = 1) -> HTTPClient {
        HTTPClient(
            session: StubURLProtocol.makeSession(),
            retryPolicy: RetryPolicy(maxAttempts: attempts, baseDelay: 0.01, maxDelay: 0.02, jitter: 0)
        )
    }

    @Test("Injects a User-Agent and returns the body")
    func injectsUserAgent() async throws {
        let host = StubURLProtocol.makeHost("ua")
        StubURLProtocol.setHandler(for: host) { _ in
            StubURLProtocol.Response(statusCode: 200, body: Data("{}".utf8))
        }

        let response = try await makeClient().data(for: URLRequest(url: URL(string: "https://\(host)/thing")!))
        #expect(response.statusCode == 200)

        let userAgent = StubURLProtocol.requests(for: host).first?.value(forHTTPHeaderField: "User-Agent")
        #expect(userAgent == HTTPDefaults.userAgent)
    }

    @Test("Maps 404 to notFound")
    func mapsNotFound() async {
        let host = StubURLProtocol.makeHost("404")
        StubURLProtocol.setHandler(for: host) { _ in StubURLProtocol.Response(statusCode: 404) }

        await #expect(throws: HTTPError.notFound) {
            _ = try await makeClient().data(for: URLRequest(url: URL(string: "https://\(host)/missing")!))
        }
    }

    @Test("Maps 429 with the Retry-After header")
    func mapsRateLimit() async {
        let host = StubURLProtocol.makeHost("429")
        StubURLProtocol.setHandler(for: host) { _ in
            StubURLProtocol.Response(statusCode: 429, headers: ["Retry-After": "12"])
        }

        await #expect(throws: HTTPError.rateLimited(retryAfter: 12)) {
            _ = try await makeClient().data(for: URLRequest(url: URL(string: "https://\(host)/limited")!))
        }
    }

    @Test("Interprets the X-RateLimit-Retry-After UNIX timestamp")
    func mapsRateLimitTimestamp() {
        let future = Date().addingTimeInterval(30).timeIntervalSince1970
        let retryAfter = HTTPClient.retryAfter(from: ["X-RateLimit-Retry-After": String(Int(future))])
        #expect(retryAfter != nil)
        #expect((retryAfter ?? 0) > 20)
    }

    @Test("Retries a server error, then succeeds")
    func retriesServerError() async throws {
        let host = StubURLProtocol.makeHost("retry")
        let counter = Counter()
        StubURLProtocol.setHandler(for: host) { _ in
            counter.increment() == 1
                ? StubURLProtocol.Response(statusCode: 503)
                : StubURLProtocol.Response(statusCode: 200, body: Data("{\"name\":\"ok\",\"count\":1}".utf8))
        }

        let payload = try await makeClient(attempts: 3).send(
            StubPayload.self,
            for: URLRequest(url: URL(string: "https://\(host)/retry")!)
        )
        #expect(payload == StubPayload(name: "ok", count: 1))
        #expect(StubURLProtocol.requests(for: host).count == 2)
    }

    @Test("Decodes a JSON body into a model")
    func decodesPayload() async throws {
        let host = StubURLProtocol.makeHost("json")
        StubURLProtocol.setHandler(for: host) { _ in
            StubURLProtocol.Response(statusCode: 200, body: Data("{\"name\":\"manga\",\"count\":7}".utf8))
        }

        let payload = try await makeClient().send(
            StubPayload.self,
            for: URLRequest(url: URL(string: "https://\(host)/json")!)
        )
        #expect(payload.name == "manga")
        #expect(payload.count == 7)
    }
}

/// Small thread-safe counter for stubbing sequential responses.
nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
        return storage
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ newValue: Int) {
        lock.lock()
        defer { lock.unlock() }
        storage = newValue
    }
}
