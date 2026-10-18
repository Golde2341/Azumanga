import Foundation
import Testing
@testable import Azumanga

/// Exercises the third-party provider runtime: JavaScript → bridge → HTTP →
/// mapping back into domain models, plus the sandbox guarantees.
@Suite("JS provider runtime")
struct JSProviderRuntimeTests {
    private func makeSource(
        host: String,
        script: String,
        capabilities: [SourceCapability] = [.search, .popular, .latest, .filters, .chapters, .pages],
        timeout: Duration = .seconds(10)
    ) throws -> JSProviderSource {
        let manifest = SourceManifest(
            id: "com.test.js",
            name: "JS Test",
            version: "1.0.0",
            allowedHosts: [host],
            capabilities: capabilities
        )
        let client = HTTPClient(
            session: StubURLProtocol.makeSession(),
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: 0.01, maxDelay: 0.02, jitter: 0)
        )
        return try JSProviderSource(
            manifest: manifest,
            script: script,
            configuration: ["language": "en", "quality": "data-saver"],
            http: client,
            callTimeout: timeout
        )
    }

    private func serveJSON(_ host: String, _ routes: [String: String]) {
        StubURLProtocol.setHandler(for: host) { request in
            guard let path = request.url?.path, let json = routes[path] else {
                return StubURLProtocol.Response(statusCode: 404, body: Data(#"{"error":"missing"}"#.utf8))
            }
            return StubURLProtocol.Response(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(json.utf8)
            )
        }
    }

    // MARK: - Happy path

    @Test("Search calls through the bridge and maps the result")
    func search() async throws {
        let host = StubURLProtocol.makeHost("js-search")
        serveJSON(host, [
            "/search": #"{"data":[{"id":"m1","title":"Alpha"},{"id":"m2","title":"Beta"}],"total":5}"#,
        ])

        let script = """
        const Source = {
            async search(query, page, filters) {
                const response = await http.get("https://\(host)/search?title=" + encodeURIComponent(query) + "&page=" + page);
                const items = response.body.data.map(function (m) { return { id: m.id, title: m.title }; });
                return { items: items, hasNextPage: (page * 2 + items.length) < response.body.total, total: response.body.total };
            }
        };
        globalThis.Source = Source;
        """

        let source = try makeSource(host: host, script: script)
        let result = try await source.search("alpha beta", page: 0, filters: [])

        #expect(result.items.map(\.title) == ["Alpha", "Beta"])
        #expect(result.items.first?.sourceId == "com.test.js")
        #expect(result.hasNextPage)
        #expect(result.totalCount == 5)

        let request = StubURLProtocol.requests(for: host).first
        #expect(request?.url?.path == "/search")
        #expect(request?.url?.query?.contains("title=alpha%20beta") == true)
        #expect(request?.value(forHTTPHeaderField: "User-Agent") == HTTPDefaults.userAgent)
    }

    @Test("Chapters and pages map into domain models")
    func chaptersAndPages() async throws {
        let host = StubURLProtocol.makeHost("js-chapters")
        serveJSON(host, [
            "/feed/m1": #"{"items":[{"id":"c1","title":"One","number":1,"volume":"1","language":"en","scanlator":"Group","publishedAt":1694534400000,"pageCount":20,"url":"https://elsewhere.test/c1"},{"id":"c2","number":2.5,"pageCount":3}]}"#,
            "/pages/c2": #"{"items":[{"url":"https://cdn.test/1.jpg","headers":{"Referer":"https://ref.test"}},{"url":"https://cdn.test/2.jpg"}]}"#,
        ])

        let script = """
        const Source = {
            async chapters(mangaId) {
                const response = await http.get("https://\(host)/feed/" + mangaId);
                return response.body;
            },
            async pages(chapterId) {
                const response = await http.get("https://\(host)/pages/" + chapterId);
                return response.body;
            }
        };
        globalThis.Source = Source;
        """

        let source = try makeSource(host: host, script: script)
        let chapters = try await source.chapters(mangaId: "m1")

        #expect(chapters.count == 2)
        #expect(chapters[0].chapterId == "c1")
        #expect(chapters[0].title == "One")
        #expect(chapters[0].number == 1)
        #expect(chapters[0].volume == "1")
        #expect(chapters[0].scanlator == "Group")
        #expect(chapters[0].pageCount == 20)
        #expect(chapters[0].publishedAt == Date(timeIntervalSince1970: 1_694_534_400))
        // An external link marks the chapter as unreadable in-app.
        #expect(chapters[0].externalURL == URL(string: "https://elsewhere.test/c1"))
        #expect(chapters[1].number == 2.5)
        #expect(chapters[1].externalURL == nil)

        let pages = try await source.pages(chapterId: "c2")
        #expect(pages.map(\.url.absoluteString) == ["https://cdn.test/1.jpg", "https://cdn.test/2.jpg"])
        #expect(pages.map(\.index) == [0, 1])
        #expect(pages[0].headers["Referer"] == "https://ref.test")
    }

    @Test("filters() is surfaced as descriptors")
    func filters() async throws {
        let host = StubURLProtocol.makeHost("js-filters")
        let script = """
        const Source = {
            async filters() {
                return { items: [
                    { id: "status", name: "Status", kind: "select", options: [
                        { id: "", name: "Any" }, { id: "ongoing", name: "Ongoing" } ] },
                    { id: "genres", name: "Genres", kind: "multiSelect", options: [
                        { id: "action", name: "Action" } ] },
                    { id: "year", name: "Year", kind: "text" }
                ] };
            }
        };
        globalThis.Source = Source;
        """

        let source = try makeSource(host: host, script: script)
        let filters = try await source.filters()

        #expect(filters.map(\.id) == ["status", "genres", "year"])
        if case .select(let options) = filters[0].kind {
            #expect(options.map(\.id) == ["", "ongoing"])
        } else {
            Issue.record("expected a select filter")
        }
        if case .multiSelect(let options) = filters[1].kind {
            #expect(options.map(\.name) == ["Action"])
        } else {
            Issue.record("expected a multi-select filter")
        }
    }

    @Test("Filter values and config reach the provider")
    func filterArgumentsAndConfig() async throws {
        let host = StubURLProtocol.makeHost("js-args")
        serveJSON(host, ["/echo": #"{"items":[]}"#])

        let script = """
        const Source = {
            async search(query, page, filters) {
                const description = config.language + "|" + config.quality + "|" + (filters.status || "") + "|" + (filters.genres || []).join("+") + "|" + page;
                await http.get("https://\(host)/echo?d=" + encodeURIComponent(description));
                return { items: [{ id: "x", title: description }], hasNextPage: false };
            }
        };
        globalThis.Source = Source;
        """

        let source = try makeSource(host: host, script: script)
        let filters: [MangaFilterValue] = [
            MangaFilterValue(filterId: "status", kind: .select("ongoing")),
            MangaFilterValue(filterId: "genres", kind: .multiSelect(["action", "drama"])),
        ]
        let result = try await source.search("q", page: 3, filters: filters)

        #expect(result.items.first?.title == "en|data-saver|ongoing|action+drama|3")
    }

    @Test("A synchronous provider works without promises")
    func synchronousProvider() async throws {
        let host = StubURLProtocol.makeHost("js-sync")
        let script = """
        const Source = {
            search: function (query, page) {
                return { items: [{ id: "sync", title: "Sync" }], hasNextPage: false };
            }
        };
        globalThis.Source = Source;
        """

        let source = try makeSource(host: host, script: script)
        let result = try await source.search("q", page: 0, filters: [])
        #expect(result.items.first?.title == "Sync")
    }

    @Test("utils helpers are available to providers")
    func utilities() async throws {
        let host = StubURLProtocol.makeHost("js-utils")
        let script = """
        const Source = {
            async search() {
                await utils.sleep(5);
                return { items: [{ id: "u", title: utils.base64Decode("aGVsbG8=") }], hasNextPage: false };
            }
        };
        globalThis.Source = Source;
        """

        let source = try makeSource(host: host, script: script)
        let result = try await source.search("q", page: 0, filters: [])
        #expect(result.items.first?.title == "hello")
    }

    // MARK: - Sandbox

    @Test("Providers cannot reach browser or host APIs")
    func sandboxGlobalsAreAbsent() async throws {
        let host = StubURLProtocol.makeHost("js-sandbox")
        let script = """
        const Source = {
            async search() {
                const names = ["fetch", "XMLHttpRequest", "document", "window", "require", "process", "setTimeout", "URL", "localStorage", "eval2", "Azumanga"];
                const kinds = names.map(function (name) { return name + ":" + typeof globalThis[name]; }).join(",");
                return { items: [{ id: "x", title: kinds }], hasNextPage: false };
            }
        };
        globalThis.Source = Source;
        """

        let source = try makeSource(host: host, script: script)
        let result = try await source.search("q", page: 0, filters: [])
        let title = try #require(result.items.first?.title)

        for name in ["fetch", "XMLHttpRequest", "document", "window", "require", "process", "setTimeout", "URL", "localStorage"] {
            #expect(title.contains("\(name):undefined"), "\(name) should not be defined in the provider sandbox")
        }
    }

    @Test("Requests to undeclared hosts are blocked")
    func hostEnforcement() async throws {
        let host = StubURLProtocol.makeHost("js-allowed")
        StubURLProtocol.setHandler(for: host) { _ in
            StubURLProtocol.Response(statusCode: 200, body: Data(#"{"items":[]}"#.utf8))
        }

        let script = """
        const Source = {
            async search() {
                const response = await http.get("https://evil.test/steal");
                return { items: [{ id: "x", title: response.body }], hasNextPage: false };
            }
        };
        globalThis.Source = Source;
        """

        let source = try makeSource(host: host, script: script)
        do {
            _ = try await source.search("q", page: 0, filters: [])
            Issue.record("expected the request to be blocked")
        } catch let error as MangaSourceError {
            #expect((error.errorDescription ?? "").contains("evil.test"))
        }
    }

    // MARK: - Failure handling

    @Test("Unsupported capabilities throw instead of failing silently")
    func unsupportedCapability() async throws {
        let host = StubURLProtocol.makeHost("js-cap")
        let script = """
        const Source = {
            async search() { return { items: [], hasNextPage: false }; }
        };
        globalThis.Source = Source;
        """

        let source = try makeSource(host: host, script: script, capabilities: [.search])
        await #expect(throws: MangaSourceError.unsupported) {
            _ = try await source.chapters(mangaId: "m1")
        }
        await #expect(throws: MangaSourceError.unsupported) {
            _ = try await source.popular(page: 0)
        }
    }

    @Test("A broken script is rejected when the provider is created")
    func brokenScript() async throws {
        let host = StubURLProtocol.makeHost("js-broken")
        #expect(throws: (any Error).self) {
            try makeSource(host: host, script: "const Source = { ")
        }
        #expect(throws: (any Error).self) {
            try makeSource(host: host, script: "var notASource = 1;")
        }
    }

    @Test("A provider that never resolves times out")
    func timeout() async throws {
        let host = StubURLProtocol.makeHost("js-hang")
        let script = """
        const Source = {
            async search() { await new Promise(function () {}); }
        };
        globalThis.Source = Source;
        """

        let source = try makeSource(host: host, script: script, timeout: .seconds(1))
        do {
            _ = try await source.search("q", page: 0, filters: [])
            Issue.record("expected a timeout")
        } catch let error as MangaSourceError {
            #expect((error.errorDescription ?? "").lowercased().contains("timed out"))
        }
    }

    @Test("A provider error surfaces the message it raised")
    func providerError() async throws {
        let host = StubURLProtocol.makeHost("js-error")
        serveJSON(host, ["/fail": #"{"detail":"nope"}"#])

        let script = """
        const Source = {
            async search() {
                const response = await http.get("https://\(host)/fail");
                if (response.body.detail) { throw new Error("custom failure: " + response.body.detail); }
                return { items: [], hasNextPage: false };
            }
        };
        globalThis.Source = Source;
        """

        let source = try makeSource(host: host, script: script)
        do {
            _ = try await source.search("q", page: 0, filters: [])
            Issue.record("expected the provider error to propagate")
        } catch let error as MangaSourceError {
            #expect((error.errorDescription ?? "").contains("custom failure"))
        }
    }

    @Test("Malformed provider output becomes a decoding error")
    func malformedOutput() async throws {
        let host = StubURLProtocol.makeHost("js-malformed")
        let script = """
        const Source = {
            async search() { return { items: [{ title: "missing id" }], hasNextPage: false }; }
        };
        globalThis.Source = Source;
        """

        let source = try makeSource(host: host, script: script)
        do {
            _ = try await source.search("q", page: 0, filters: [])
            Issue.record("expected a decoding error")
        } catch let error as MangaSourceError {
            if case .decoding = error {} else {
                Issue.record("expected .decoding, got \(error)")
            }
        }
    }
}
