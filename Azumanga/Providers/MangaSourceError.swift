import Foundation

/// Errors surfaced by sources to the UI. Kept user-facing: every case has a
/// readable description so views never have to interpret raw error types.
nonisolated enum MangaSourceError: Error, LocalizedError, Sendable, Equatable {
    case unsupported
    case notFound
    case cancelled
    case disconnected
    case rateLimited(retryAfter: TimeInterval?)
    case network(String)
    case decoding(String)
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            "This source does not support that action."
        case .notFound:
            "The requested content could not be found."
        case .cancelled:
            "The request was cancelled."
        case .disconnected:
            "You appear to be offline. Check your connection and try again."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                "Rate limited by the source. Try again in \(Int(retryAfter.rounded()))s."
            } else {
                "Rate limited by the source. Try again shortly."
            }
        case .network(let message):
            "Network error: \(message)"
        case .decoding(let message):
            "The source returned unexpected data: \(message)"
        case .provider(let message):
            "Source error: \(message)"
        }
    }
}
