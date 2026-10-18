import Foundation
import Testing
@testable import Azumanga

@Suite("MangaDexMapper")
struct MangaDexMapperTests {
    private let decoder = HTTPClient.makeDecoder()

    private let mangaJSON = """
    {
      "result": "ok",
      "response": "entity",
      "data": {
        "id": "a1c7c817-4e59-43b7-9365-09675a149a6f",
        "type": "manga",
        "attributes": {
          "title": { "en": "The Summer Guest" },
          "altTitles": [ { "ja": "\\u590f\\u306e\\u5ba2" } ],
          "description": { "en": "A quiet story about a haunting." },
          "status": "ongoing",
          "year": 2021,
          "contentRating": "suggestive",
          "lastChapter": "85",
          "tags": [
            { "id": "t1", "type": "tag", "attributes": { "name": { "en": "Romance" }, "group": "genre" } },
            { "id": "t2", "type": "tag", "attributes": { "name": { "en": "Ghosts" }, "group": "theme" } },
            { "id": "t3", "type": "tag", "attributes": { "name": { "en": "Award Winning" }, "group": "format" } }
          ]
        },
        "relationships": [
          { "id": "cov", "type": "cover_art", "attributes": { "fileName": "cover.png" } },
          { "id": "auth", "type": "author", "attributes": { "name": "Jane Doe" } },
          { "id": "art", "type": "artist", "attributes": { "name": "John Roe" } }
        ]
      }
    }
    """

    @Test("Maps a manga entity into the domain model")
    func mapsManga() throws {
        let envelope = try decoder.decode(MDEnvelope<MDEntity<MDMangaAttributes>>.self, from: Data(mangaJSON.utf8))
        let manga = try MangaDexMapper.manga(from: envelope.data)

        #expect(manga.sourceId == "org.mangadex")
        #expect(manga.mangaId == "a1c7c817-4e59-43b7-9365-09675a149a6f")
        #expect(manga.title == "The Summer Guest")
        #expect(manga.altTitles == ["夏の客"])
        #expect(manga.author == "Jane Doe")
        #expect(manga.artist == "John Roe")
        #expect(manga.status == .ongoing)
        #expect(manga.contentRating == .suggestive)
        #expect(manga.year == 2021)
        #expect(manga.lastChapter == "85")
        #expect(manga.genres == ["Romance", "Ghosts"])
        #expect(manga.coverURL?.absoluteString == "https://uploads.mangadex.org/covers/a1c7c817-4e59-43b7-9365-09675a149a6f/cover.png.512.jpg")
    }

    @Test("Handles missing attributes gracefully")
    func handlesMissingAttributes() throws {
        let json = """
        { "id": "x", "type": "manga", "attributes": null, "relationships": [] }
        """
        let entity = try decoder.decode(MDEntity<MDMangaAttributes>.self, from: Data(json.utf8))
        #expect(throws: MangaSourceError.self) {
            try MangaDexMapper.manga(from: entity)
        }
    }

    @Test("Standalone altTitles strings are tolerated")
    func toleratesStringAltTitles() throws {
        let json = """
        {
          "result": "ok",
          "data": {
            "id": "x", "type": "manga",
            "attributes": {
              "title": { "en": "Main" },
              "altTitles": [ "Plain Alt" ],
              "status": "completed"
            },
            "relationships": []
          }
        }
        """
        let envelope = try decoder.decode(MDEnvelope<MDEntity<MDMangaAttributes>>.self, from: Data(json.utf8))
        let manga = try MangaDexMapper.manga(from: envelope.data)
        #expect(manga.altTitles == ["Plain Alt"])
        #expect(manga.status == .completed)
        #expect(manga.coverURL == nil)
    }

    @Test("Prefers an English altTitle when the primary title is not English")
    func prefersEnglishAltTitle() throws {
        let json = """
        {
          "result": "ok",
          "data": {
            "id": "x", "type": "manga",
            "attributes": {
              "title": { "ko-ro": "Na Honjaman Level-Up" },
              "altTitles": [ { "ko": "\\ub098" }, { "en": "Solo Leveling" } ],
              "status": "completed"
            },
            "relationships": []
          }
        }
        """
        let envelope = try decoder.decode(MDEnvelope<MDEntity<MDMangaAttributes>>.self, from: Data(json.utf8))
        let manga = try MangaDexMapper.manga(from: envelope.data)
        #expect(manga.title == "Solo Leveling")
    }

    @Test("Chapter number parsing tolerates blanks and non-numerics")
    func chapterNumberParsing() {
        #expect(MangaDexMapper.chapterNumber(from: "12.5") == 12.5)
        #expect(MangaDexMapper.chapterNumber(from: "7") == 7)
        #expect(MangaDexMapper.chapterNumber(from: "") == nil)
        #expect(MangaDexMapper.chapterNumber(from: nil) == nil)
        #expect(MangaDexMapper.chapterNumber(from: "Omake") == nil)
    }

    @Test("Maps a chapter entity including scanlation group and dates")
    func mapsChapter() throws {
        let json = """
        {
          "id": "c1", "type": "chapter",
          "attributes": {
            "title": "The Long Night",
            "volume": "2",
            "chapter": "12.5",
            "pages": 20,
            "translatedLanguage": "en",
            "readableAt": "2021-05-10T13:37:54+00:00"
          },
          "relationships": [
            { "id": "g1", "type": "scanlation_group", "attributes": { "name": "Scan Group" } }
          ]
        }
        """
        let entity = try decoder.decode(MDEntity<MDChapterAttributes>.self, from: Data(json.utf8))
        let chapter = MangaDexMapper.chapter(from: entity, mangaId: "m1")

        #expect(chapter.chapterId == "c1")
        #expect(chapter.mangaId == "m1")
        #expect(chapter.title == "The Long Night")
        #expect(chapter.number == 12.5)
        #expect(chapter.volume == "2")
        #expect(chapter.pageCount == 20)
        #expect(chapter.scanlator == "Scan Group")
        #expect(chapter.language == "en")
        #expect(chapter.publishedAt != nil)
    }

    @Test("Builds page URLs from the at-home server payload")
    func mapsPages() throws {
        let json = """
        {
          "result": "ok",
          "baseUrl": "https://uploads.mangadex.org",
          "chapter": {
            "hash": "3303dd03ac8d27452cce3f2a882e94b2",
            "data": [ "1.png", "2.png" ],
            "dataSaver": [ "1.jpg", "2.jpg" ]
          }
        }
        """
        let atHome = try decoder.decode(MDAtHome.self, from: Data(json.utf8))

        let saver = MangaDexMapper.pages(from: atHome, quality: .dataSaver)
        #expect(saver.count == 2)
        #expect(saver[0].url.absoluteString == "https://uploads.mangadex.org/data-saver/3303dd03ac8d27452cce3f2a882e94b2/1.jpg")
        #expect(saver[0].index == 0)
        #expect(saver[1].index == 1)

        let original = MangaDexMapper.pages(from: atHome, quality: .data)
        #expect(original[1].url.absoluteString == "https://uploads.mangadex.org/data/3303dd03ac8d27452cce3f2a882e94b2/2.png")

        // First-party uploads host: no MangaDex@Home health reporting needed.
        #expect(saver[0].healthReportURL == nil)
    }

    @Test("Third-party MangaDex@Home nodes are flagged for health reporting")
    func healthReportingForNodes() throws {
        let json = """
        {
          "result": "ok",
          "baseUrl": "https://cmdxd98sb0x3yprd.mangadex.network",
          "chapter": { "hash": "abc", "data": [ "1.png" ], "dataSaver": [ "1.jpg" ] }
        }
        """
        let atHome = try decoder.decode(MDAtHome.self, from: Data(json.utf8))
        let pages = MangaDexMapper.pages(from: atHome, quality: .dataSaver)
        #expect(pages.first?.healthReportURL == URL(string: "https://api.mangadex.network/report"))
    }
}
