import Foundation
import JavaScriptCore

/// Runs a single provider's JavaScript in its own `JSVirtualMachine`/`JSContext`
/// on a dedicated serial queue. JavaScriptCore is not thread-safe, so every
/// touch of the context happens on that queue; async callers await the result.
///
/// Untrusted code never gets more than the bridge in `JSContextBridge` — there is
/// no access to the filesystem, the app's objects, or native code.
nonisolated final class JSProviderHost: @unchecked Sendable {
    private let manifest: SourceManifest
    private let queue: DispatchQueue
    private let virtualMachine: JSVirtualMachine
    private let context: JSContext
    private let bridge: JSContextBridge
    private let callTimeout: Duration

    /// Set when a call times out, so later calls fail fast instead of queueing
    /// behind a script that will never finish.
    private let broken = LockedFlag()

    init(
        manifest: SourceManifest,
        script: String,
        configuration: [String: String],
        http: HTTPClient,
        callTimeout: Duration = .seconds(30),
        log: @escaping @Sendable (String) -> Void
    ) throws {
        let queue = DispatchQueue(label: "org.azumanga.provider.\(manifest.id)")
        guard let virtualMachine = JSVirtualMachine() else {
            throw MangaSourceError.provider("Could not create a JavaScript runtime")
        }
        let bridge = JSContextBridge(
            http: http,
            allowedHosts: manifest.allowedHosts,
            queue: queue,
            log: log
        )

        var setupError: Error?
        var createdContext: JSContext?
        queue.sync {
            guard let context = JSContext(virtualMachine: virtualMachine) else {
                setupError = MangaSourceError.provider("Could not create a JavaScript context")
                return
            }
            context.exceptionHandler = { _, exception in
                log("Uncaught: \(exception?.toString() ?? "unknown error")")
            }
            bridge.install(into: context, configuration: configuration)

            // Helper used to marshal results back to Swift as JSON.
            context.evaluateScript(
                "globalThis.__azumangaStringify = function (value) { return JSON.stringify(value === undefined ? null : value); };"
            )
            context.evaluateScript(script, withSourceURL: URL(string: "provider://\(manifest.id)/\(manifest.main)"))
            if let exception = context.exception {
                setupError = MangaSourceError.provider("Script failed to load: \(exception.toString() ?? "unknown error")")
                return
            }
            guard let source = context.objectForKeyedSubscript("Source"), source.isObject else {
                setupError = MangaSourceError.provider("Script must define a global `Source` object")
                return
            }
            createdContext = context
        }

        if let setupError { throw setupError }
        guard let createdContext else {
            throw MangaSourceError.provider("Could not prepare the provider runtime")
        }

        self.manifest = manifest
        self.queue = queue
        self.virtualMachine = virtualMachine
        self.context = createdContext
        self.bridge = bridge
        self.callTimeout = callTimeout
    }

    /// Calls `Source.<method>(...)` and returns the resolved value as JSON.
    func call(_ method: String, arguments: [Any]) async throws -> Data {
        if broken.isSet {
            throw MangaSourceError.provider("Provider runtime is no longer usable")
        }

        let boxedArguments = UncheckedBox(arguments)
        let gate = SingleResume()
        let watchdog = TaskBox()

        do {
            let data = try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !broken.isSet else {
                        gate.finish(continuation, with: .failure(MangaSourceError.provider("Provider runtime is no longer usable")))
                        return
                    }
                    performInvoke(
                        method: method,
                        arguments: boxedArguments.value,
                        gate: gate,
                        watchdog: watchdog,
                        continuation: continuation
                    )
                }

                // Bounded execution: a provider that never settles must not hang
                // the app. On expiry the host is retired so later calls fail fast
                // instead of queueing behind the stuck script.
                let queue = queue
                let timeout = callTimeout
                let task = Task { [self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    broken.set()
                    queue.async { [self] in broken.set() }
                    gate.finish(
                        continuation,
                        with: .failure(MangaSourceError.provider("Provider timed out during \(method)"))
                    )
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

    // MARK: - Private

    private func performInvoke(
        method: String,
        arguments: [Any],
        gate: SingleResume,
        watchdog: TaskBox,
        continuation: CheckedContinuation<Data, any Error>
    ) {
        func finish(_ result: Result<Data, any Error>) {
            watchdog.cancel()
            gate.finish(continuation, with: result)
        }

        guard let source = context.objectForKeyedSubscript("Source"),
              let function = source.objectForKeyedSubscript(method),
              !function.isUndefined
        else {
            finish(.failure(MangaSourceError.unsupported))
            return
        }

        guard let result = function.call(withArguments: arguments) else {
            finish(.failure(currentExceptionError(fallback: "\(method)() failed")))
            return
        }
        if let exception = context.exception {
            context.exception = nil
            finish(.failure(MangaSourceError.provider(exception.toString() ?? "\(method)() threw")))
            return
        }

        // Non-promise returns (sync providers) short-circuit immediately.
        guard Self.isPromise(result) else {
            finish(Self.jsonData(from: result, method: method, context: context))
            return
        }

        let resolve: @convention(block) (JSValue?) -> Void = { [self] value in
            finish(Self.jsonData(from: value, method: method, context: context))
        }
        let reject: @convention(block) (JSValue?) -> Void = { message in
            finish(.failure(MangaSourceError.provider(message?.toString() ?? "\(method)() rejected")))
        }

        result.invokeMethod("then", withArguments: [resolve, reject])
    }

    private func currentExceptionError(fallback: String) -> MangaSourceError {
        if let exception = context.exception {
            context.exception = nil
            return MangaSourceError.provider(exception.toString() ?? fallback)
        }
        return MangaSourceError.provider(fallback)
    }

    private static func isPromise(_ value: JSValue) -> Bool {
        guard value.isObject,
              let then = value.objectForKeyedSubscript("then"),
              !then.isUndefined
        else { return false }
        return then.isObject
    }

    private static func jsonData(from value: JSValue?, method: String, context: JSContext) -> Result<Data, any Error> {
        guard let value else {
            return .failure(MangaSourceError.provider("\(method)() resolved with no value"))
        }
        guard let stringify = context.objectForKeyedSubscript("__azumangaStringify"),
              let json = stringify.call(withArguments: [value]).toString(),
              json != "null", json != "undefined"
        else {
            return .failure(MangaSourceError.provider("\(method)() returned nothing"))
        }
        return .success(Data(json.utf8))
    }
}

/// Guarantees a checked continuation is resumed exactly once, even when the
/// provider, the timeout watchdog and a failure path race each other.
nonisolated final class SingleResume: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func finish(_ continuation: CheckedContinuation<Data, any Error>, with result: Result<Data, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.resume(with: result)
    }
}

/// Holds the timeout watchdog so it can be cancelled when the call finishes.
nonisolated final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
    }

    func cancel() {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}

/// A lock-protected flag usable from any thread.
nonisolated final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        defer { lock.unlock() }
        value = true
    }
}
