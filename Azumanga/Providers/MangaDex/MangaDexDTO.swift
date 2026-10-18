import Foundation

/// MangaDex localised string maps arrive as `{ "en": "…" }`, and `altTitles`
/// entries are occasionally plain strings. This tolerates both shapes.
nonisolated struct MDLocalizedString: Codable, Sendable {
    var values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dictionary = try? container.decode([String: String].self) {
            values = dictionary
        } else if let string = try? container.decode(String.self) {
            values = ["und": string]
        } else {
            values = [:]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    /// Best-effort English value, falling back to whatever is available.
    var preferred: String? {
        values["en"] ?? values["ja-ro"] ?? values["ja"] ?? values.sorted { $0.key < $1.key }.first?.value
    }
}

nonisolated struct MDEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    var result: String
    var response: String?
    var data: Payload
    var limit: Int?
    var offset: Int?
    var total: Int?
}

nonisolated struct MDEntity<Attributes: Codable & Sendable>: Codable, Sendable {
    var id: String
    var type: String?
    var attributes: Attributes?
    var relationships: [MDRelationship]?
}

nonisolated struct MDRelationship: Codable, Sendable {
    var id: String
    var type: String
    /// Relationship attributes vary by type; a single permissive shape covers
    /// cover art (`fileName`), authors/artists and scanlation groups (`name`).
    var attributes: MDAttributes?

    nonisolated struct MDAttributes: Codable, Sendable {
        var fileName: String?
        var name: String?
        var locale: String?
    }
}

nonisolated struct MDMangaAttributes: Codable, Sendable {
    var title: MDLocalizedString
    var altTitles: [MDLocalizedString]?
    var description: MDLocalizedString?
    var status: String?
    var year: Int?
    var contentRating: String?
    var lastChapter: String?
    var lastVolume: String?
    var publicationDemographic: String?
    var originalLanguage: String?
    var availableTranslatedLanguages: [String]?
    var tags: [MDTag]?
}

nonisolated struct MDTag: Codable, Sendable {
    var id: String
    var type: String?
    var attributes: Attributes?

    nonisolated struct Attributes: Codable, Sendable {
        var name: MDLocalizedString
        var group: String?
    }
}

nonisolated struct MDChapterAttributes: Codable, Sendable {
    var title: String?
    var volume: String?
    var chapter: String?
    var pages: Int?
    var translatedLanguage: String?
    var externalUrl: String?
    var publishAt: Date?
    var readableAt: Date?
    var createdAt: Date?
    var updatedAt: Date?
}

nonisolated struct MDAtHome: Codable, Sendable {
    var baseUrl: String
    var chapter: Chapter

    nonisolated struct Chapter: Codable, Sendable {
        var hash: String
        var data: [String]
        var dataSaver: [String]
    }
}
