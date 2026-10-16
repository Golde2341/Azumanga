import Foundation

/// Token-bucket rule for a group of requests.
nonisolated struct RateLimitRule: Sendable {
    /// Host this rule applies to; `nil` matches any host.
    var host: String?
    /// Path prefix this rule applies to; `nil` matches any path.
    var pathPrefix: String?
    /// Sustained refill rate, tokens per second.
    var ratePerSecond: Double
    /// Maximum tokens (i.e. burst allowance).
    var burst: Double

    init(host: String? = nil, pathPrefix: String? = nil, ratePerSecond: Double, burst: Double) {
        self.host = host
        self.pathPrefix = pathPrefix
        self.ratePerSecond = ratePerSecond
        self.burst = burst
    }

    func matches(host requestHost: String, path: String) -> Bool {
        if let host, !host.isEmpty, host.caseInsensitiveCompare(requestHost) != .orderedSame {
            return false
        }
        if let pathPrefix, !path.hasPrefix(pathPrefix) {
            return false
        }
        return true
    }

    /// Specificity: higher wins. Exact-host + path beats wildcards.
    var specificity: Int {
        (host == nil ? 0 : 2) + (pathPrefix == nil ? 0 : 1) + (pathPrefix?.count ?? 0)
    }

    var key: String { "\(host ?? "*")|\(pathPrefix ?? "*")" }
}

/// Injectable time source so rate-limiting behaviour is deterministic in tests.
nonisolated struct RateLimiterClock: Sendable {
    var now: @Sendable () -> TimeInterval
    var sleep: @Sendable (TimeInterval) async throws -> Void

    static func live() -> RateLimiterClock {
        RateLimiterClock(
            now: { TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
            sleep: { seconds in
                guard seconds > 0 else { return }
                try await Task.sleep(for: .seconds(seconds))
            }
        )
    }
}

/// Serialises outbound requests with a token bucket per matching rule, so the
/// app stays within a source's published limits instead of getting throttled.
actor RateLimiter {
    private struct Bucket {
        var tokens: Double
        var lastRefill: TimeInterval
    }

    private let rules: [RateLimitRule]
    private let clock: RateLimiterClock
    private var buckets: [String: Bucket] = [:]

    init(rules: [RateLimitRule] = RateLimitRule.mangadexDefaults, clock: RateLimiterClock = .live()) {
        self.rules = rules
        self.clock = clock
    }

    /// Suspends until a token is available for the given host/path, then consumes it.
    func acquire(host: String, path: String) async throws {
        let rule = rule(for: host, path: path)
        while true {
            try Task.checkCancellation()
            let now = clock.now()
            var bucket = buckets[rule.key] ?? Bucket(tokens: rule.burst, lastRefill: now)
            let elapsed = max(0, now - bucket.lastRefill)
            bucket.tokens = min(rule.burst, bucket.tokens + elapsed * rule.ratePerSecond)
            bucket.lastRefill = now

            if bucket.tokens >= 1 {
                bucket.tokens -= 1
                buckets[rule.key] = bucket
                return
            }

            buckets[rule.key] = bucket
            let deficit = (1 - bucket.tokens) / max(rule.ratePerSecond, .leastNonzeroMagnitude)
            try await clock.sleep(min(deficit, 5))
        }
    }

    private func rule(for host: String, path: String) -> RateLimitRule {
        Self.selectRule(from: rules, host: host, path: path)
    }

    /// Picks the most specific matching rule, falling back to a polite default.
    nonisolated static func selectRule(from rules: [RateLimitRule], host: String, path: String) -> RateLimitRule {
        rules
            .filter { $0.matches(host: host, path: path) }
            .max(by: { $0.specificity < $1.specificity })
            ?? RateLimitRule(ratePerSecond: 8, burst: 8)
    }
}

nonisolated extension RateLimitRule {
    /// Published MangaDex limits: ~5 req/s globally, and 40 req/min on the
    /// at-home server endpoint. Image hosts are given a polite default so we
    /// don't hammer the volunteer CDN.
    static let mangadexDefaults: [RateLimitRule] = [
        RateLimitRule(host: "api.mangadex.org", pathPrefix: "/at-home/server", ratePerSecond: 40.0 / 60.0, burst: 40),
        RateLimitRule(host: "api.mangadex.org", ratePerSecond: 5, burst: 5),
        RateLimitRule(host: "uploads.mangadex.org", ratePerSecond: 5, burst: 5),
    ]
}
