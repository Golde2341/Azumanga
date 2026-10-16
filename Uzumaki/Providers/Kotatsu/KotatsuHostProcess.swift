import Foundation
import os

/// Where to find the parser host and the JVM that runs it.
nonisolated struct KotatsuHostConfiguration: Sendable, Equatable {
    /// The executable to launch: a `java` binary, or anything else in tests.
    var executable: URL
    /// Arguments, e.g. `["-jar", <host jar>, "--cache-dir=<path>"]`.
    var arguments: [String]
    /// Directory the host writes fetched page images into.
    var cacheDirectory: URL

    var jar: URL? {
        guard let index = arguments.firstIndex(of: "-jar"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    /// The standard launch used for the real host.
    static func java(_ java: URL, jar: URL, cacheDirectory: URL) -> KotatsuHostConfiguration {
        KotatsuHostConfiguration(
            executable: java,
            arguments: ["-jar", jar.path, "--cache-dir=\(cacheDirectory.path)"],
            cacheDirectory: cacheDirectory
        )
    }
}

/// Resolves the host for development and for a bundled app.
///
/// Development order: an explicit override, then the local build output. In a
/// shipped app the host and a trimmed runtime live in the bundle. When nothing is
/// found the app simply offers no Kotatsu sources — it never fails to launch.
nonisolated enum KotatsuHostLocator {
    static let environmentOverride = "UZUMAKI_PARSER_HOST"

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> KotatsuHostConfiguration? {
        guard let jar = resolveJar(environment: environment, bundle: bundle, fileManager: fileManager) else {
            return nil
        }
        guard let java = resolveJava(environment: environment, bundle: bundle, fileManager: fileManager) else {
            return nil
        }
        return KotatsuHostConfiguration.java(java, jar: jar, cacheDirectory: cacheDirectory(fileManager: fileManager))
    }

    private static func resolveJar(
        environment: [String: String],
        bundle: Bundle,
        fileManager: FileManager
    ) -> URL? {
        if let override = environment[environmentOverride], fileManager.isExecutableFile(atPath: override) == false,
           fileManager.fileExists(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        if let bundled = bundle.url(forResource: "uzumaki-parser-host-all", withExtension: "jar") {
            return bundled
        }
        if let bundled = bundle.url(
            forResource: "uzumaki-parser-host-all",
            withExtension: "jar",
            subdirectory: "ParserHost"
        ) {
            return bundled
        }
        // Local development: the build output of ParserHost/.
        let development = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Kotatsu
            .deletingLastPathComponent()  // Providers
            .deletingLastPathComponent()  // Uzumaki
            .deletingLastPathComponent()  // project root
            .appendingPathComponent("ParserHost/build/libs/uzumaki-parser-host-all.jar")
        return fileManager.fileExists(atPath: development.path) ? development : nil
    }

    private static func resolveJava(
        environment: [String: String],
        bundle: Bundle,
        fileManager: FileManager
    ) -> URL? {
        // A bundled trimmed runtime is the only thing guaranteed on a user's Mac.
        if let runtime = bundle.url(forResource: "java", withExtension: nil, subdirectory: "ParserHost/runtime/bin") {
            return runtime
        }
        if let home = environment["JAVA_HOME"] {
            let candidate = URL(fileURLWithPath: home).appendingPathComponent("bin/java")
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        for path in [
            "/Library/Java/JavaVirtualMachines/jdk-17.jdk/Contents/Home/bin/java",
            "/opt/homebrew/opt/openjdk@17/bin/java",
            "/usr/local/opt/openjdk@17/bin/java",
            "/usr/bin/java",
        ] where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func cacheDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("Uzumaki/KotatsuHost", isDirectory: true)
    }
}

/// Talks to the parser host: newline-delimited JSON over stdin/stdout, one
/// request per line, responses correlated by id.
actor KotatsuHostProcess {
    private let configuration: KotatsuHostConfiguration
    private let logger = Logger(subsystem: "org.uzumaki", category: "kotatsu-host")
    private let defaultTimeout: Duration

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var buffer = Data()
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var nextIdentifier = 1
    private var stderrTail = Data()

    init(configuration: KotatsuHostConfiguration, defaultTimeout: Duration = .seconds(120)) {
        self.configuration = configuration
        self.defaultTimeout = defaultTimeout
    }

    // MARK: - Lifecycle

    private func ensureRunning() throws {
        if let process, process.isRunning { return }

        try FileManager.default.createDirectory(
            at: configuration.cacheDirectory,
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = configuration.executable
        process.arguments = configuration.arguments

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            Task { await self.ingest(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            Task { await self.captureStderr(data) }
        }
        process.terminationHandler = { [weak self] process in
            Task { [weak self] in
                guard let self else { return }
                await self.handleTermination(status: process.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            throw MangaSourceError.provider(
                "Could not start the parser host at \(configuration.executable.path): \(error.localizedDescription)"
            )
        }

        self.process = process
        self.input = input.fileHandleForWriting
        self.output = output.fileHandleForReading
        self.errors = errors.fileHandleForReading
        buffer.removeAll()
        stderrTail.removeAll()
        let executableName = configuration.executable.lastPathComponent
        logger.info("parser host started with \(executableName, privacy: .public)")
    }

    func shutdown() {
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
        output = nil
        errors = nil
        failPending(with: MangaSourceError.provider("The parser host was shut down."))
    }

    private func handleTermination(status: Int32) {
        let detail = stderrTail.isEmpty ? "" : " — \(String(decoding: stderrTail.suffix(400), as: UTF8.self))"
        logger.error("parser host exited with status \(status)")
        process = nil
        input = nil
        output = nil
        errors = nil
        buffer.removeAll()
        failPending(with: MangaSourceError.provider("The parser host stopped unexpectedly (status \(status))\(detail)"))
    }

    private func failPending(with error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Calling

    func call<P: Encodable>(_ method: String, parameters: P?, timeout: Duration? = nil) async throws -> Data {
        try ensureRunning()
        guard let input else {
            throw MangaSourceError.provider("The parser host is not running.")
        }

        let identifier = nextIdentifier
        nextIdentifier += 1

        var object: [String: Any] = ["id": identifier, "method": method]
        if let parameters,
           let encoded = try? JSONEncoder().encode(parameters),
           let decoded = try? JSONSerialization.jsonObject(with: encoded) {
            object["params"] = decoded
        }
        let line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        let gate = SingleResume()
        let watchdog = TaskBox()
        let deadline = timeout ?? defaultTimeout

        do {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                pending[identifier] = continuation

                do {
                    var payload = line
                    payload.append(0x0A)
                    try input.write(contentsOf: payload)
                } catch {
                    pending.removeValue(forKey: identifier)
                    gate.finish(continuation, with: .failure(
                        MangaSourceError.provider("Could not write to the parser host: \(error.localizedDescription)")
                    ))
                    return
                }

                // A provider that never answers must not wedge the call forever.
                let task = Task { [weak self] in
                    try? await Task.sleep(for: deadline)
                    guard !Task.isCancelled else { return }
                    await self?.timeOut(identifier: identifier, method: method, gate: gate)
                }
                watchdog.set(task)
            }
            watchdog.cancel()
            return data
        } catch {
            watchdog.cancel()
            throw error
        }
    }

    private func timeOut(identifier: Int, method: String, gate: SingleResume) {
        guard let continuation = pending.removeValue(forKey: identifier) else { return }
        gate.finish(continuation, with: .failure(
            MangaSourceError.provider("The source timed out during \(method).")
        ))
    }

    // MARK: - Reading

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            logger.debug("ignoring malformed host line")
            return
        }

        // `{"event":"ready"}` and any other unsolicited events.
        if object["event"] != nil {
            logger.debug("host event: \(String(describing: object["event"]), privacy: .public)")
            return
        }

        guard let identifier = object["id"] as? Int,
              let continuation = pending.removeValue(forKey: identifier)
        else { return }

        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "The source reported an error."
            continuation.resume(throwing: MangaSourceError.provider(message))
            return
        }

        guard let result = object["result"],
              let data = try? JSONSerialization.data(withJSONObject: result) else {
            continuation.resume(throwing: MangaSourceError.decoding("The host returned no result."))
            return
        }
        continuation.resume(returning: data)
    }

    private func captureStderr(_ data: Data) {
        stderrTail.append(data)
        if stderrTail.count > 8_192 {
            stderrTail.removeFirst(stderrTail.count - 8_192)
        }
    }
}

/// Placeholder so calls without parameters can share one generic path.
nonisolated struct EmptyParameters: Encodable, Sendable {}

/// The calling surface a source needs. Lets `KotatsuSource` be tested against a
/// canned host without starting a JVM.
///
/// The requirement is deliberately untyped (`Data` in, `Data` out): a generic
/// metatype parameter cannot cross into an actor without tripping Swift 6's
/// non-Sendable checks, so decoding lives in the extension below instead.
nonisolated protocol KotatsuHostCalling: Sendable {
    func call<P: Encodable>(_ method: String, parameters: P?, timeout: Duration?) async throws -> Data
}

nonisolated extension KotatsuHostCalling {
    func call(_ method: String, timeout: Duration? = nil) async throws -> Data {
        try await call(method, parameters: Optional<EmptyParameters>.none, timeout: timeout)
    }

    func call<R: Decodable>(_ method: String, as type: R.Type, timeout: Duration? = nil) async throws -> R {
        try await call(method, parameters: Optional<EmptyParameters>.none, as: type, timeout: timeout)
    }

    func call<P: Encodable, R: Decodable>(
        _ method: String,
        parameters: P?,
        as type: R.Type,
        timeout: Duration? = nil
    ) async throws -> R {
        let data = try await call(method, parameters: parameters, timeout: timeout)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MangaSourceError.decoding("Unexpected host response: \(HTTPClient.describe(error))")
        }
    }
}

extension KotatsuHostProcess: KotatsuHostCalling {}
