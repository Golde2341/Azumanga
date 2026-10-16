import Foundation

nonisolated enum HTTPDefaults {
    static let userAgent = "Uzumaki/1.0 (macOS; +https://github.com/lapepo/Uzumaki)"
}

/// Shared ISO-8601 parsing. `ISO8601DateFormatter` is documented as thread-safe,
/// so a single instance is reused across decoders.
private nonisolated final class ISO8601Parsers: @unchecked Sendable {
    private let fractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
    }

    func date(from string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }
}

/// A raw HTTP reply with case-insensitive header access.
nonisolated struct HTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let headers: [String: String]

    var isSuccess: Bool { (200..<300).contains(statusCode) }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Async HTTP client shared by every source. It injects a real `User-Agent`
/// (required by MangaDex), serialises requests through a `RateLimiter`, retries
/// transient failures, and maps status codes onto `HTTPError`.
actor HTTPClient {
    private let session: URLSession
    private let userAgent: String
    private let rateLimiter: RateLimiter
    private let retryPolicy: RetryPolicy

    init(
        session: URLSession? = nil,
        userAgent: String = HTTPDefaults.userAgent,
        rateLimiter: RateLimiter = RateLimiter(),
        retryPolicy: RetryPolicy = .default
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120
            configuration.httpMaximumConnectionsPerHost = 6
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
        self.userAgent = userAgent
        self.rateLimiter = rateLimiter
        self.retryPolicy = retryPolicy
    }

    /// Performs a request, retrying transient failures and rate limits.
    func data(for request: URLRequest, allowRetry: Bool = true) async throws -> HTTPResponse {
        let prepared = applyDefaults(to: request)
        guard let url = prepared.url else {
            throw HTTPError.invalidRequest("Request has no URL")
        }
        guard let host = url.host, !host.isEmpty else {
            throw HTTPError.invalidURL(url.absoluteString)
        }

        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            try await rateLimiter.acquire(host: host, path: url.path)

            do {
                let (data, response) = try await session.data(for: prepared)
                guard let http = response as? HTTPURLResponse else {
                    throw HTTPError.transport("Non-HTTP response")
                }
                let headers = Self.headerMap(http)
                if (200..<300).contains(http.statusCode) {
                    return HTTPResponse(data: data, statusCode: http.statusCode, headers: headers)
                }

                let error = Self.map(status: http.statusCode, headers: headers)
                let retryAfter = Self.retryAfter(from: headers)
                if allowRetry,
                   attempt < retryPolicy.maxAttempts,
                   retryPolicy.isRetryable(status: http.statusCode),
                   let delay = retryPolicy.delay(forAttempt: attempt, status: http.statusCode, retryAfter: retryAfter) {
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                throw error
            } catch let urlError as URLError {
                if urlError.code == .cancelled { throw CancellationError() }
                if allowRetry,
                   attempt < retryPolicy.maxAttempts,
                   retryPolicy.isRetryable(transportError: urlError),
                   let delay = retryPolicy.delay(forAttempt: attempt, status: nil, retryAfter: nil) {
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                throw Self.map(transportError: urlError)
            }
        }
    }

    /// Performs a request and decodes the body as JSON.
    func send<T: Decodable & Sendable>(
        _ type: T.Type,
        for request: URLRequest,
        decoder: JSONDecoder = HTTPClient.makeDecoder(),
        allowRetry: Bool = true
    ) async throws -> T {
        let response = try await data(for: request, allowRetry: allowRetry)
        do {
            return try decoder.decode(type, from: response.data)
        } catch {
            throw HTTPError.decoding(Self.describe(error))
        }
    }

    // MARK: - Helpers

    private func applyDefaults(to request: URLRequest) -> URLRequest {
        var request = request
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        return request
    }

    nonisolated static func makeDecoder() -> JSONDecoder {
        let parsers = ISO8601Parsers()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = parsers.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised date: \(string)")
        }
        return decoder
    }

    nonisolated static func headerMap(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                result[key] = value
            }
        }
        return result
    }

    nonisolated static func map(status: Int, headers: [String: String]) -> HTTPError {
        switch status {
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 429: .rateLimited(retryAfter: retryAfter(from: headers))
        case 500...599: .server(status: status)
        default: .unexpectedStatus(status)
        }
    }

    nonisolated static func map(transportError: URLError) -> HTTPError {
        switch transportError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            .transport(transportError.localizedDescription)
        default:
            .transport(transportError.localizedDescription)
        }
    }

    nonisolated static func retryAfter(from headers: [String: String]) -> TimeInterval? {
        for name in ["Retry-After", "X-RateLimit-Retry-After"] {
            guard let raw = headers.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value else {
                continue
            }
            if let seconds = TimeInterval(raw) {
                // X-RateLimit-Retry-After is a UNIX timestamp, not a duration.
                if name.hasPrefix("X-") && seconds > 1_000_000 {
                    return max(0, seconds - Date().timeIntervalSince1970)
                }
                return max(0, seconds)
            }
        }
        return nil
    }

    nonisolated static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return error.localizedDescription }
        switch decodingError {
        case .keyNotFound(let key, _):
            return "missing key '\(key.stringValue)'"
        case .typeMismatch(_, let context):
            return "type mismatch at \(path(context.codingPath))"
        case .valueNotFound(_, let context):
            return "missing value at \(path(context.codingPath))"
        case .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return error.localizedDescription
        }
    }

    nonisolated private static func path(_ codingPath: [CodingKey]) -> String {
        codingPath.map(\.stringValue).joined(separator: ".")
    }
}
