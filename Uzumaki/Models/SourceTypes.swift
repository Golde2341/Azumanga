import Foundation

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
}
