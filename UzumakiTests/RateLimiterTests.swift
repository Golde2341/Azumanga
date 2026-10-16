import Foundation
import Testing
@testable import Uzumaki

@Suite("RateLimiter")
struct RateLimiterTests {
    @Test("Burst is consumed immediately, then requests pace to the refill rate")
    func pacing() async throws {
        let fake = FakeClock()
        let limiter = RateLimiter(
            rules: [RateLimitRule(host: "example.com", ratePerSecond: 1, burst: 2)],
            clock: fake.rateLimiterClock
        )

        try await limiter.acquire(host: "example.com", path: "/a")
        try await limiter.acquire(host: "example.com", path: "/b")
        #expect(fake.now == 0)

        try await limiter.acquire(host: "example.com", path: "/c")
        #expect(fake.now >= 1.0)
    }

    @Test("Most specific rule wins: at-home endpoint over the global MangaDex rule")
    func ruleSelection() {
        let atHome = RateLimiter.selectRule(
            from: RateLimitRule.mangadexDefaults,
            host: "api.mangadex.org",
            path: "/at-home/server/abc"
        )
        #expect(atHome.pathPrefix == "/at-home/server")
        #expect(atHome.ratePerSecond == 40.0 / 60.0)

        let global = RateLimiter.selectRule(
            from: RateLimitRule.mangadexDefaults,
            host: "api.mangadex.org",
            path: "/manga"
        )
        #expect(global.pathPrefix == nil)
        #expect(global.ratePerSecond == 5)
    }

    @Test("Unknown hosts fall back to the polite default bucket")
    func unknownHostFallback() {
        let rule = RateLimiter.selectRule(from: RateLimitRule.mangadexDefaults, host: "cdn.other.test", path: "/x")
        #expect(rule.ratePerSecond == 8)
        #expect(rule.host == nil)
    }

    @Test("Separate rules use independent buckets")
    func independentBuckets() async throws {
        let fake = FakeClock()
        let limiter = RateLimiter(
            rules: [
                RateLimitRule(host: "a.test", ratePerSecond: 1, burst: 1),
                RateLimitRule(host: "b.test", ratePerSecond: 1, burst: 1),
            ],
            clock: fake.rateLimiterClock
        )

        try await limiter.acquire(host: "a.test", path: "/")
        try await limiter.acquire(host: "b.test", path: "/")
        #expect(fake.now == 0)
    }
}
