import Foundation
import Testing
@testable import Uzumaki

@Suite("RetryPolicy")
struct RetryPolicyTests {
    @Test("Only 408, 429 and 5xx are retryable")
    func retryableStatuses() {
        let policy = RetryPolicy.default
        #expect(policy.isRetryable(status: 429))
        #expect(policy.isRetryable(status: 408))
        #expect(policy.isRetryable(status: 503))
        #expect(!policy.isRetryable(status: 404))
        #expect(!policy.isRetryable(status: 401))
    }

    @Test("Non-retryable statuses produce no delay")
    func noDelayForPermanentFailures() {
        let policy = RetryPolicy.default
        #expect(policy.delay(forAttempt: 1, status: 404, retryAfter: nil) == nil)
    }

    @Test("Server-provided retryAfter takes precedence and is clamped")
    func retryAfterPrecedence() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 1, maxDelay: 10, jitter: 0)
        #expect(policy.delay(forAttempt: 1, status: 429, retryAfter: 3) == 3)
        #expect(policy.delay(forAttempt: 1, status: 429, retryAfter: 999) == 10)
    }

    @Test("Backoff grows exponentially and stays within maxDelay")
    func exponentialBackoff() {
        let policy = RetryPolicy(maxAttempts: 6, baseDelay: 1, maxDelay: 8, jitter: 0)
        #expect(policy.delay(forAttempt: 1, status: 500, retryAfter: nil) == 1)
        #expect(policy.delay(forAttempt: 2, status: 500, retryAfter: nil) == 2)
        #expect(policy.delay(forAttempt: 3, status: 500, retryAfter: nil) == 4)
        #expect(policy.delay(forAttempt: 4, status: 500, retryAfter: nil) == 8)
        #expect(policy.delay(forAttempt: 5, status: 500, retryAfter: nil) == 8)
    }

    @Test("Transport errors classified for retry")
    func transportClassification() {
        let policy = RetryPolicy.default
        #expect(policy.isRetryable(transportError: URLError(.timedOut)))
        #expect(policy.isRetryable(transportError: URLError(.networkConnectionLost)))
        #expect(!policy.isRetryable(transportError: URLError(.unsupportedURL)))
    }
}
