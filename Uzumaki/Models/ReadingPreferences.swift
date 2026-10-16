import Foundation

nonisolated enum ReadingDirection: String, CaseIterable, Identifiable, Sendable, Codable {
    case leftToRight
    case rightToLeft

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftToRight: "Left to right"
        case .rightToLeft: "Right to left"
        }
    }

    var toggled: ReadingDirection {
        self == .leftToRight ? .rightToLeft : .leftToRight
    }
}

nonisolated enum ReaderLayoutKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case vertical
    case horizontal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vertical: "Vertical scroll"
        case .horizontal: "Horizontal paging"
        }
    }
}

nonisolated enum PageMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case single
    case double

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .single: "Single page"
        case .double: "Double page"
        }
    }
}

nonisolated enum PageFitMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case fitScreen
    case fitWidth
    case fitHeight
    case original

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fitScreen: "Fit screen"
        case .fitWidth: "Fit width"
        case .fitHeight: "Fit height"
        case .original: "Original size"
        }
    }
}

nonisolated enum PageBackground: String, CaseIterable, Identifiable, Sendable, Codable {
    case black
    case darkGray
    case white

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .black: "Black"
        case .darkGray: "Dark gray"
        case .white: "White"
        }
    }
}
