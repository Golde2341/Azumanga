import Foundation

/// A filter descriptor surfaced by a source, used to build filter UI dynamically.
nonisolated struct MangaFilter: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var kind: Kind

    nonisolated enum Kind: Hashable, Sendable {
        case text
        case toggle
        case select(options: [Option])
        case multiSelect(options: [Option])
        case group(filters: [MangaFilter])
    }

    nonisolated struct Option: Identifiable, Hashable, Sendable {
        let id: String
        var name: String

        init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

/// A concrete value supplied for a `MangaFilter`.
nonisolated struct MangaFilterValue: Hashable, Sendable {
    let filterId: String
    var kind: Kind

    nonisolated enum Kind: Hashable, Sendable {
        case text(String)
        case toggle(Bool)
        case select(String)
        case multiSelect([String])
    }

    init(filterId: String, kind: Kind) {
        self.filterId = filterId
        self.kind = kind
    }
}
