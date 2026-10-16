import CoreGraphics
import Foundation
import ImageIO
@testable import Uzumaki

/// Encodes a small solid-colour PNG, for exercising the image paths.
nonisolated func makePNGData(width: Int, height: Int) -> Data {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!

    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// Deterministic, manually advanced clock used to test time-dependent behaviour
/// without real waiting.
nonisolated final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval

    init(start: TimeInterval = 0) {
        self.time = start
    }

    var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return time
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        time += interval
    }

    /// A `RateLimiterClock` whose "sleeping" simply advances virtual time.
    var rateLimiterClock: RateLimiterClock {
        RateLimiterClock(
            now: { [self] in now },
            sleep: { [self] seconds in advance(by: seconds) }
        )
    }
}

/// A `URLProtocol` stub that serves canned responses without touching the
/// network. Handlers are registered **per host** so suites running in parallel
/// never observe each other's state.
nonisolated final class StubURLProtocol: URLProtocol {
    struct Response {
        var statusCode: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: @Sendable (URLRequest) -> Response] = [:]
    nonisolated(unsafe) private static var recorded: [String: [URLRequest]] = [:]

    /// A unique host so a test's stub cannot be seen by any other test.
    static func makeHost(_ label: String = "stub") -> String {
        "\(label)-\(UUID().uuidString.prefix(8).lowercased()).test"
    }

    static func setHandler(for host: String, _ handler: @escaping @Sendable (URLRequest) -> Response) {
        lock.lock()
        defer { lock.unlock() }
        handlers[host] = handler
        recorded[host] = []
    }

    static func requests(for host: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded[host] ?? []
    }

    private static func handler(for host: String) -> (@Sendable (URLRequest) -> Response)? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[host]
    }

    private static func record(_ request: URLRequest, host: String) {
        lock.lock()
        defer { lock.unlock() }
        recorded[host, default: []].append(request)
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.record(request, host: host)

        guard let handler = Self.handler(for: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let response = handler(request)
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
