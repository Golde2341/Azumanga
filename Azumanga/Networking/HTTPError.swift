import Foundation

/// HTTP failures, mapped from status codes and transport errors.
nonisolated enum HTTPError: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest(String)
    case invalidURL(String)
    case transport(String)
    case rateLimited(retryAfter: TimeInterval?)
    case notFound
    case unauthorized
    case forbidden
    case server(status: Int)
    case unexpectedStatus(Int)
    case decoding(String)

    var statusCode: Int? {
        switch self {
        case .notFound: 404
        case .unauthorized: 401
        case .forbidden: 403
        case .server(let status): status
        case .unexpectedStatus(let status): status
        case .rateLimited: 429
        default: nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            "Malformed request: \(message)"
        case .invalidURL(let value):
            "Invalid URL: \(value)"
        case .transport(let message):
            "Network error: \(message)"
        case .rateLimited(let retryAfter):
            if let retryAfter {
                "Rate limited. Retry in \(Int(retryAfter.rounded()))s."
            } else {
                "Rate limited. Please try again shortly."
            }
        case .notFound:
            "Not found (404)."
        case .unauthorized:
            "Unauthorized (401)."
        case .forbidden:
            "Access denied (403)."
        case .server(let status):
            "Server error (\(status))."
        case .unexpectedStatus(let status):
            "Unexpected response (\(status))."
        case .decoding(let message):
            "Could not read the response: \(message)"
        }
    }

    /// Convert to the source-facing error type used throughout the app.
    var asSourceError: MangaSourceError {
        switch self {
        case .notFound: .notFound
        case .rateLimited(let retryAfter): .rateLimited(retryAfter: retryAfter)
        case .decoding(let message): .decoding(message)
        case .invalidURL(let value): .network("Invalid URL: \(value)")
        case .invalidRequest(let message): .network(message)
        case .transport(let message): .network(message)
        case .unauthorized, .forbidden, .server, .unexpectedStatus: .network(errorDescription ?? "Request failed")
        }
    }
}
