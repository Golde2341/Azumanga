import Foundation
import Testing
@testable import Azumanga

@Suite("MangaDexAPI")
struct MangaDexAPITests {
    private let api = MangaDexAPI()
    private let configuration = MangaDexConfiguration(language: "en", quality: .dataSaver, contentRatings: [.safe], pageSize: 25)

    private func queryItems(_ request: URLRequest) -> [String: String] {
        let url = request.url!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // Later duplicates win; sufficient for these assertions.
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { _, last in last }
    }

    private func allQueryValues(_ request: URLRequest, named name: String) -> [String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.filter { $0.name == name }.map { $0.value ?? "" }
    }

    @Test("Popular request orders by follow count and paginates")
    func popularRequest() {
        let request = api.popularRequest(page: 2, configuration: configuration)
        let items = queryItems(request)

        #expect(request.url?.path == "/manga")
        #expect(items["order[followedCount]"] == "desc")
        #expect(items["limit"] == "25")
        #expect(items["offset"] == "50")
        #expect(items["hasAvailableChapters"] == "true")
        #expect(allQueryValues(request, named: "includes[]").contains("cover_art"))
        #expect(allQueryValues(request, named: "contentRating[]") == ["safe"])
    }

    @Test("Search request carries the query and relevance ordering")
    func searchRequest() {
        let request = api.searchRequest(query: "  ghost  ", page: 0, filters: [], configuration: configuration)
        let items = queryItems(request)

        #expect(items["title"] == "ghost")
        #expect(items["order[relevance]"] == "desc")
        #expect(items["offset"] == "0")
    }

    @Test("Empty search falls back to a browse ordering")
    func emptySearch() {
        let request = api.searchRequest(query: "   ", page: 0, filters: [], configuration: configuration)
        let items = queryItems(request)
        #expect(items["title"] == nil)
        #expect(items["order[followedCount]"] == "desc")
    }

    @Test("Filter values are translated into array query parameters")
    func filterMapping() {
        let filters: [MangaFilterValue] = [
            MangaFilterValue(filterId: "status", kind: .select("ongoing")),
            MangaFilterValue(filterId: "demographic", kind: .select("")),
            MangaFilterValue(filterId: "originalLanguage", kind: .multiSelect(["ja", "ko"])),
            MangaFilterValue(filterId: "year", kind: .text("2021")),
            MangaFilterValue(filterId: "unused", kind: .text("   ")),
        ]
        let items = MangaDexAPI.queryItems(for: filters)

        #expect(items.contains { $0.name == "status[]" && $0.value == "ongoing" })
        #expect(!items.contains { $0.name == "demographic[]" })
        #expect(items.filter { $0.name == "originalLanguage[]" }.count == 2)
        #expect(items.contains { $0.name == "year" && $0.value == "2021" })
        #expect(!items.contains { $0.name == "unused" })
    }

    @Test("Chapter feed pins language, ordering and paging")
    func chapterFeed() {
        let request = api.chaptersRequest(mangaId: "m1", offset: 500, limit: 500, configuration: configuration)
        let items = queryItems(request)

        #expect(request.url?.path == "/manga/m1/feed")
        #expect(items["translatedLanguage[]"] == "en")
        #expect(items["order[chapter]"] == "asc")
        #expect(items["order[volume]"] == "asc")
        #expect(items["limit"] == "500")
        #expect(items["offset"] == "500")
        // `includeExternalUrl=1` silently drops every chapter for many manga, so
        // the parameter must never be sent.
        #expect(items["includeExternalUrl"] == nil)
    }

    @Test("At-home request targets the chapter server endpoint")
    func atHomeRequest() {
        let request = api.atHomeRequest(chapterId: "c1")
        #expect(request.url?.path == "/at-home/server/c1")
    }
}
