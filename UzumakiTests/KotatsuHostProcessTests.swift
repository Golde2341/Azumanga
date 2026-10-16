import Foundation
import Testing
@testable import Uzumaki

/// Drives `KotatsuHostProcess` against a stub host so framing, correlation,
/// timeouts and crash handling are tested without a JVM.
///
/// The stub is POSIX `sh`, not python: `/usr/bin/python3` on macOS is an xcrun
/// shim, and xcrun refuses to run inside the app sandbox the tests execute in.
@Suite("Kotatsu host transport", .serialized)
struct KotatsuHostProcessTests {
    private static let stubScript = #"""
    #!/bin/sh
    # Deliberately noisy: the host must ignore anything that is not protocol.
    echo "this is not json"
    echo '{"event":"ready","protocol":1,"sourceCount":1370}'
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
      key=$(printf '%s' "$line" | sed -n 's/.*"key":"\([^"]*\)".*/\1/p')
      case "$line" in
        *'"method":"slow"'*) sleep 30 ;;
        *'"method":"die"'*) exit 3 ;;
        *'"method":"fail"'*)
          printf '{"id":%s,"error":{"code":"parser_error","message":"boom"}}\n' "$id" ;;
        *)
          if [ -n "$key" ]; then
            printf '{"id":%s,"result":{"protocol":1,"sourceCount":1370,"echo":{"key":"%s"}}}\n' "$id" "$key"
          else
            printf '{"id":%s,"result":{"protocol":1,"sourceCount":1370}}\n' "$id"
          fi ;;
      esac
    done
    """#

    private func makeProcess(timeout: Duration = .seconds(10)) throws -> (KotatsuHostProcess, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uzumaki-stub-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let script = directory.appendingPathComponent("stub_host.sh")
        try Data(Self.stubScript.utf8).write(to: script)

        let configuration = KotatsuHostConfiguration(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path],
            cacheDirectory: directory.appendingPathComponent("cache", isDirectory: true)
        )
        return (KotatsuHostProcess(configuration: configuration, defaultTimeout: timeout), directory)
    }

    nonisolated private struct PingResult: Decodable, Sendable, Equatable {
        var protocolVersion: Int
        var sourceCount: Int
        var echo: Echo?

        struct Echo: Decodable, Sendable, Equatable {
            var key: String
        }

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol"
            case sourceCount
            case echo
        }
    }

    @Test("Starts the host, ignores non-protocol output, and decodes a result")
    func ping() async throws {
        let (host, directory) = try makeProcess()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await host.call("ping", as: PingResult.self)
        #expect(result.protocolVersion == 1)
        #expect(result.sourceCount == 1370)
        await host.shutdown()
    }

    @Test("Correlates concurrent requests that come back out of order")
    func correlatesRequests() async throws {
        let (host, directory) = try makeProcess()
        defer { try? FileManager.default.removeItem(at: directory) }

        async let first = host.call(
            "ping",
            parameters: ["key": "first"],
            as: PingResult.self
        )
        async let second = host.call(
            "ping",
            parameters: ["key": "second"],
            as: PingResult.self
        )

        let (one, two) = try await (first, second)
        #expect(one.echo?.key == "first")
        #expect(two.echo?.key == "second")
        await host.shutdown()
    }

    @Test("Surfaces host errors as provider errors, with the host's message")
    func surfacesErrors() async throws {
        let (host, directory) = try makeProcess()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await host.call("fail", as: PingResult.self)
            Issue.record("expected the call to fail")
        } catch let error as MangaSourceError {
            #expect((error.errorDescription ?? "").contains("boom"))
        }
        await host.shutdown()
    }

    @Test("A host that never answers times out instead of hanging")
    func timesOut() async throws {
        let (host, directory) = try makeProcess(timeout: .seconds(1))
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = ContinuousClock.now
        do {
            _ = try await host.call("slow", as: PingResult.self)
            Issue.record("expected a timeout")
        } catch let error as MangaSourceError {
            #expect((error.errorDescription ?? "").lowercased().contains("timed out"))
        }
        #expect(started.duration(to: .now) < .seconds(8))
        await host.shutdown()
    }

    @Test("A host that dies fails the in-flight call rather than hanging")
    func hostDies() async throws {
        let (host, directory) = try makeProcess()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await host.call("die", as: PingResult.self)
            Issue.record("expected the call to fail")
        } catch let error as MangaSourceError {
            #expect((error.errorDescription ?? "").contains("stopped unexpectedly"))
        }
        await host.shutdown()
    }

    @Test("Missing host is reported clearly instead of crashing")
    func missingHost() async throws {
        let configuration = KotatsuHostConfiguration(
            executable: URL(fileURLWithPath: "/nonexistent/java"),
            arguments: [],
            cacheDirectory: FileManager.default.temporaryDirectory
        )
        let host = KotatsuHostProcess(configuration: configuration, defaultTimeout: .seconds(2))
        do {
            _ = try await host.call("ping", as: PingResult.self)
            Issue.record("expected a launch failure")
        } catch let error as MangaSourceError {
            #expect((error.errorDescription ?? "").contains("Could not start the parser host"))
        }
    }

    @Test("The locator finds the locally built host when it exists")
    func locatorFindsDevelopmentHost() {
        let configuration = KotatsuHostLocator.resolve()
        // Not fatal when absent: the app degrades to no Kotatsu sources.
        if let configuration {
            #expect(configuration.jar?.lastPathComponent == "uzumaki-parser-host-all.jar")
            #expect(FileManager.default.isExecutableFile(atPath: configuration.executable.path))
        }
    }

    @Test(
        "Talks to the real parser host",
        .enabled(if: ProcessInfo.processInfo.environment["UZUMAKI_LIVE_TESTS"] == "1")
    )
    func realHost() async throws {
        let configuration = try #require(
            KotatsuHostLocator.resolve(),
            "Build ParserHost/ and install a JDK 17 to run this test"
        )
        let host = KotatsuHostProcess(configuration: configuration, defaultTimeout: .seconds(180))

        let ping = try await host.call("ping", as: PingResult.self)
        #expect(ping.protocolVersion == 1)
        #expect(ping.sourceCount > 1000)
        await host.shutdown()
    }
}
