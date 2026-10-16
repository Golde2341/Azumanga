import Foundation

/// A single page image. `headers` lets a source attach per-page request headers;
/// they are intentionally empty for MangaDex image hosts, which reject auth.
nonisolated struct Page: Identifiable, Hashable, Sendable {
    let index: Int
    let url: URL
    var headers: [String: String]
    /// Optional endpoint that accepts delivery success/failure reports. MangaDex
    /// asks clients to report MangaDex@Home node health so unhealthy mirrors are
    /// taken out of rotation.
    var healthReportURL: URL?

    var id: Int { index }

    init(index: Int, url: URL, headers: [String: String] = [:], healthReportURL: URL? = nil) {
        self.index = index
        self.url = url
        self.headers = headers
        self.healthReportURL = healthReportURL
    }
}
