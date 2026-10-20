import Foundation

/// Where a source's implementation comes from. The UI groups by this.
nonisolated enum SourceProviderKind: String, Sendable, Hashable, CaseIterable {
    /// Compiled into the app as native Swift.
    case builtIn
    /// A JavaScript provider installed by the user at runtime.
    case scripted
    /// A parser running in the external parser host.
    case kotatsuHost
}

/// Result of the last check that a source actually answers.
nonisolated enum SourceHealth: String, Sendable, Codable, Hashable, CaseIterable {
    case untested
    case working
    case failing
}

/// A source that can be cheaply checked for liveness. The app offers this as a
/// bulk "test all sources" action; sources that don't implement it are probed
/// through their ordinary listing method instead.
nonisolated protocol SourceProbing: Sendable {
    /// - Returns: how many items the source returned. Throwing means unusable.
    func probe() async throws -> Int
}

/// Optional behaviours a source may advertise. Views use these to decide which
/// affordances to show (e.g. a filter button only if `.filters` is supported).
nonisolated enum SourceCapability: String, Codable, CaseIterable, Sendable, Hashable {
    case search
    case popular
    case latest
    case filters
    case chapters
    case pages
}

nonisolated enum PublicationStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case unknown
    case ongoing
    case completed
    case hiatus
    case cancelled

    var displayName: String {
        switch self {
        case .unknown: "Unknown"
        case .ongoing: "Ongoing"
        case .completed: "Completed"
        case .hiatus: "Hiatus"
        case .cancelled: "Cancelled"
        }
    }
}

nonisolated enum ContentRating: String, Codable, Sendable, Hashable, CaseIterable {
    case safe
    case suggestive
    case erotica
    case pornographic

    var displayName: String {
        switch self {
        case .safe: "Safe"
        case .suggestive: "Suggestive"
        case .erotica: "Erotica"
        case .pornographic: "Pornographic"
        }
    }

    /// Ratings considered acceptable for the default (non-adult) browsing experience.
    static var safeDefaults: Set<ContentRating> { [.safe, .suggestive] }

    /// Whether this rating denotes explicitly adult material.
    var isNSFW: Bool {
        self == .erotica || self == .pornographic
    }
}
