import Foundation
import Testing
@testable import Azumanga

/// A host that answers from canned payloads, so adapter behaviour is tested
/// without starting a JVM. Records which methods were called.
private actor CannedHost: KotatsuHostCalling {
    private var payloads: [String: String]
    private(set) var calls: [String] = []
    /// Raw parameters per method, so tests can assert what the parser was handed.
    private(set) var parameters: [String: [Data]] = [:]

    init(payloads: [String: String]) {
        self.payloads = payloads
    }

    func call<P: Encodable>(_ method: String, parameters: P?, timeout: Duration?) async throws -> Data {
        calls.append(method)
        if let parameters, let encoded = try? JSONEncoder().encode(parameters) {
            self.parameters[method, default: []].append(encoded)
        }
        guard let payload = payloads[method] else {
            throw MangaSourceError.unsupported
        }
        return Data(payload.utf8)
    }

    var recordedCalls: [String] { calls }
    func callCount(_ method: String) -> Int { calls.filter { $0 == method }.count }

    /// The `manga.url` sent with the most recent `details` call.
    func lastDetailsMangaURL() -> String? {
        guard let data = parameters["details"]?.last,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let manga = object["manga"] as? [String: Any]
        else { return nil }
        return manga["url"] as? String
    }
}

private let mangasJSON = """
{"items":[
  {"id":1001,"title":"Berserk","altTitles":["Berserk Alt"],"url":"/manga/1001",
   "publicUrl":"https://example.test/manga/1001","rating":0.9,"coverUrl":"https://cdn.test/1001.jpg",
   "description":"Dark fantasy.","state":"ONGOING","contentRating":"SUGGESTIVE",
   "sourceKey":"MANGAPILL","authors":["Kentaro Miura"],
   "tags":[{"title":"Action","key":"action"},{"title":"Horror","key":"horror"}]},
  {"id":1002,"title":"Untitled Sample","url":"/manga/1002","coverUrl":"https://cdn.test/1002.jpg"}
]}
"""

private let detailsJSON = """
{"id":1001,"title":"Berserk","altTitles":[],"url":"/manga/1001",
 "publicUrl":"https://example.test/manga/1001","coverUrl":"https://cdn.test/1001.jpg",
 "state":"ONGOING","contentRating":"SUGGESTIVE","sourceKey":"MANGAPILL","authors":["Kentaro Miura"],
 "tags":[],"description":"Dark fantasy.",
 "chapters":[
   {"id":5001,"title":"Golden Age","number":1.0,"volume":1,"url":"/ch/5001","scanlator":"Group","uploadDate":1694534400000},
   {"id":5002,"title":null,"number":2.0,"volume":0,"url":"/ch/5002","scanlator":null,"uploadDate":1694620800000}
 ]}
"""

private let pagesJSON = """
{"items":[
  {"id":9001,"url":"/page/1","resolvedUrl":"https://cdn.test/1.jpg","preview":null},
  {"id":9002,"url":"/page/2","resolvedUrl":null,"preview":null}
]}
"""

private let filterOptionsJSON = """
{"sortOrders":["POPULARITY_DESC","UPDATED_DESC"],"capabilities":
 {"search":true,"searchWithFilters":true,"multipleTags":false,"tagsExclusion":false,"year":true,"yearRange":false,"author":false},
 "options":{"tags":[],"states":["ONGOING","FINISHED"],"contentRatings":["SAFE","ADULT"],"contentTypes":["MANGA"],"demographics":["SHOUNEN"]}}
"""

@Suite("Kotatsu source adapter")
struct KotatsuSourceTests {
    private func makeSource(
        mangas: String = mangasJSON,
        details: String = detailsJSON,
        pages: String = pagesJSON,
        filters: String = filterOptionsJSON
    ) -> (KotatsuSource, CannedHost) {
        let host = CannedHost(payloads: [
            "list": mangas,
            "details": details,
            "pages": pages,
            "filterOptions": filters,
        ])
        let source = KotatsuSource(
            source: KotatsuSourceDTO(
                key: "MANGAPILL",
                title: "MangaPill",
                locale: "en",
                contentType: "MANGA",
                broken: false
            ),
            host: host,
            // No on-disk catalog: these tests must not see each other's state.
            catalogDirectory: nil
        )
        return (source, host)
    }

    @Test("Metadata describes the source")
    func metadata() {
        let (source, _) = makeSource()
        #expect(source.id == "kotatsu.MANGAPILL")
        #expect(source.name == "MangaPill")
        #expect(source.language == "en")
        #expect(!source.isBuiltIn)
        #expect(source.capabilities.contains(.pages))
    }

    @Test("A source with no locale reports itself as multilingual")
    func multilingualLocale() {
        let host = CannedHost(payloads: [:])
        let source = KotatsuSource(
            source: KotatsuSourceDTO(key: "MANGADEX", title: "MangaDex", locale: "", contentType: "MANGA", broken: false),
            host: host
        )
        #expect(source.language == "multi")
    }

    @Test("Browse maps manga, wrapping covers for host fetching")
    func browse() async throws {
        let (source, _) = makeSource()
        let result = try await source.popular(page: 0)

        #expect(result.items.count == 2)
        #expect(result.hasNextPage)

        let first = try #require(result.items.first)
        #expect(first.sourceId == "kotatsu.MANGAPILL")
        #expect(first.mangaId == "1001")
        #expect(first.title == "Berserk")
        #expect(first.author == "Kentaro Miura")
        #expect(first.genres == ["Action", "Horror"])
        #expect(first.status == .ongoing)
        #expect(first.contentRating == .suggestive)
        #expect(first.webURL?.absoluteString == "https://example.test/manga/1001")

        // Covers must go through the host, so they arrive wrapped.
        let cover = try #require(first.coverURL)
        let parsed = try #require(HostImageURL.parse(cover))
        #expect(parsed.sourceKey == "MANGAPILL")
        #expect(parsed.remote.absoluteString == "https://cdn.test/1001.jpg")
    }

    @Test("Search passes the query, sort and filter values through")
    func searchParameters() async throws {
        let (source, host) = makeSource()
        let filters: [MangaFilterValue] = [
            MangaFilterValue(filterId: "sort", kind: .select("UPDATED_DESC")),
            MangaFilterValue(filterId: "states", kind: .multiSelect(["ONGOING"])),
            MangaFilterValue(filterId: "contentRatings", kind: .multiSelect(["SAFE", "ADULT"])),
            MangaFilterValue(filterId: "yearFrom", kind: .text("2000")),
        ]

        _ = try await source.search("berserk", page: 2, filters: filters)
        #expect(await host.callCount("list") == 1)
    }

    @Test("Details and chapters share a single host call")
    func detailsAreDeduplicated() async throws {
        let (source, host) = makeSource()

        // This mirrors MangaDetailModel, which requests both concurrently.
        async let details = source.mangaDetails(id: "1001")
        async let chapters = source.chapters(mangaId: "1001")

        let (manga, list) = try await (details, chapters)

        #expect(manga.title == "Berserk")
        #expect(list.count == 2)
        #expect(list[0].chapterId == "5001")
        #expect(list[0].title == "Golden Age")
        #expect(list[0].number == 1)
        #expect(list[0].volume == "1")
        #expect(list[0].scanlator == "Group")
        #expect(list[0].publishedAt == Date(timeIntervalSince1970: 1_694_534_400))
        // A zero volume means "no volume", not volume zero.
        #expect(list[1].volume == nil)
        #expect(list[1].title == nil)

        #expect(await host.callCount("details") == 1, "details must not be fetched twice")
    }

    @Test("Pages are wrapped for host fetching, preferring the resolved URL")
    func pages() async throws {
        let (source, _) = makeSource()
        _ = try await source.chapters(mangaId: "1001")  // populates the chapter index

        let pages = try await source.pages(chapterId: "5001")
        #expect(pages.count == 2)
        #expect(pages.map(\.index) == [0, 1])

        let first = try #require(HostImageURL.parse(pages[0].url))
        #expect(first.remote.absoluteString == "https://cdn.test/1.jpg")

        // The second page had no resolved URL, so the raw one is used.
        let second = try #require(HostImageURL.parse(pages[1].url))
        #expect(second.remote.absoluteString == "/page/2")
    }

    @Test("Requesting pages for an unknown chapter explains what to do")
    func pagesWithoutChapter() async throws {
        let (source, _) = makeSource()
        do {
            _ = try await source.pages(chapterId: "9999")
            Issue.record("expected an error")
        } catch let error as MangaSourceError {
            #expect((error.errorDescription ?? "").lowercased().contains("not been loaded"))
        }
    }

    @Test("Filters are exposed with the host's parameter names as ids")
    func filters() async throws {
        let (source, _) = makeSource()
        let filters = try await source.filters()

        // `year` is supported by the fixture but `author` is not, so only one of the
        // two text filters appears.
        #expect(filters.map(\.id) == ["sort", "states", "contentRatings", "types", "demographics", "yearFrom"])
        if case .select(let options) = filters[0].kind {
            #expect(options.map(\.id) == ["POPULARITY_DESC", "UPDATED_DESC"])
            #expect(options.first?.name == "Popularity desc")
        } else {
            Issue.record("expected a select filter for sort")
        }
        if case .multiSelect(let options) = filters[1].kind {
            #expect(options.map(\.id) == ["ONGOING", "FINISHED"])
        } else {
            Issue.record("expected a multi-select filter for states")
        }
        if case .text = filters[5].kind {} else {
            Issue.record("expected a text filter for the year")
        }
    }

    @Test("Latest asks for a recency sort when the source offers one")
    func latestUsesRecencySort() async throws {
        let (source, host) = makeSource()
        _ = try await source.latest(page: 0)
        // A sort was requested rather than relying on the parser default.
        #expect(await host.callCount("list") == 1)
        #expect(await host.callCount("filterOptions") >= 1)
    }

    @Test("A host that does not know a method surfaces as unsupported")
    func unsupportedMethod() async throws {
        let host = CannedHost(payloads: [:])
        let source = KotatsuSource(
            source: KotatsuSourceDTO(key: "X", title: "X", locale: "en", contentType: "MANGA", broken: false),
            host: host
        )
        await #expect(throws: MangaSourceError.unsupported) {
            _ = try await source.filters()
        }
    }

    @Test("Manga state and content rating map onto our enums")
    func enumMapping() {
        #expect(KotatsuMapper.publicationStatus(from: "FINISHED") == .completed)
        #expect(KotatsuMapper.publicationStatus(from: "PAUSED") == .hiatus)
        #expect(KotatsuMapper.publicationStatus(from: "ABANDONED") == .cancelled)
        #expect(KotatsuMapper.publicationStatus(from: "RESTRICTED") == .unknown)
        #expect(KotatsuMapper.publicationStatus(from: nil) == .unknown)
        #expect(KotatsuMapper.contentRating(from: "ADULT") == .erotica)
        #expect(KotatsuMapper.contentRating(from: "SUGGESTIVE") == .suggestive)
        #expect(KotatsuMapper.contentRating(from: nil) == .safe)
    }

    @Test("An opened manga survives a relaunch, so the parser still gets its URL")
    func catalogSurvivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("azumanga-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let descriptor = KotatsuSourceDTO(
            key: "MANGAPILL", title: "MangaPill", locale: "en", contentType: "MANGA", broken: false
        )

        // First run: browse and open a title, which populates the catalog.
        let firstHost = CannedHost(payloads: ["list": mangasJSON, "details": detailsJSON])
        let first = KotatsuSource(source: descriptor, host: firstHost, catalogDirectory: directory)
        _ = try await first.search("berserk", page: 0, filters: [])
        _ = try await first.mangaDetails(id: "1001")

        // Second run: a fresh instance, as after a relaunch.
        let secondHost = CannedHost(payloads: ["details": detailsJSON])
        let second = KotatsuSource(source: descriptor, host: secondHost, catalogDirectory: directory)
        let reloaded = try await second.mangaDetails(id: "1001")

        #expect(reloaded.title == "Berserk")
        // The catalog satisfies the request, so a relaunch needs no network call.
        #expect(await secondHost.callCount("details") == 0)

        // And it stored the URL the parser needs, which is the whole point: without
        // it the parser would be handed an id with no page to fetch.
        let stored = try Data(contentsOf: directory.appendingPathComponent("MANGAPILL.catalog.json"))
        let entries = try JSONDecoder().decode([KotatsuMangaDTO].self, from: stored)
        let persisted = try #require(entries.first { $0.id == 1001 })
        #expect(persisted.url == "/manga/1001")
        #expect(persisted.chapters?.count == 2)

        // Chapters opened from the library still work.
        let chapters = try await second.chapters(mangaId: "1001")
        #expect(chapters.count == 2)
    }

    @Test("Without a catalog the parser is given a minimal payload, not a wrong URL")
    func withoutCatalog() async throws {
        let host = CannedHost(payloads: ["details": detailsJSON])
        let source = KotatsuSource(
            source: KotatsuSourceDTO(key: "MANGAPILL", title: "MangaPill", locale: "en", contentType: "MANGA", broken: false),
            host: host,
            catalogDirectory: nil
        )
        _ = try await source.mangaDetails(id: "1001")
        #expect(await host.lastDetailsMangaURL() == "")
    }
}
