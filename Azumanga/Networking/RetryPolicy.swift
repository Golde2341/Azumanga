import Foundation

/// Decides whether a failed request is worth retrying and how long to wait.
nonisolated struct RetryPolicy: Sendable {
    var maxAttempts: Int
    var baseDelay: TimeInterval
    var maxDelay: TimeInterval
    var jitter: Double

    static let `default` = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, maxDelay: 16, jitter: 0.3)

    init(maxAttempts: Int = 3, baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 16, jitter: Double = 0.3) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    func isRetryable(status: Int) -> Bool {
        status == 429 || status == 408 || (500...599).contains(status)
    }

    func isRetryable(transportError: URLError) -> Bool {
        switch transportError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .notConnectedToInternet,
             .dnsLookupFailed,
             .resourceUnavailable,
             .secureConnectionFailed:
            true
        default:
            false
        }
    }

    /// Delay before the next attempt, or `nil` when the failure is not retryable.
    /// An explicit server-provided `retryAfter` always takes precedence.
    func delay(forAttempt attempt: Int, status: Int?, retryAfter: TimeInterval?) -> TimeInterval? {
        if let retryAfter {
            return min(max(retryAfter, 0), maxDelay)
        }
        if let status, !isRetryable(status: status) {
            return nil
        }
        let exponential = baseDelay * pow(2, Double(max(0, attempt - 1)))
        let capped = min(exponential, maxDelay)
        let factor = 1 + Double.random(in: -jitter...jitter)
        return max(0, capped * factor)
    }
}
