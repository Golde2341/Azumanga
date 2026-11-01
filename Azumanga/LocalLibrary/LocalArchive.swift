import Foundation

/// Unpacks a CBZ, which is a ZIP.
///
/// macOS ships no API that reads ZIP containers — Foundation and AppleArchive
/// cannot open one, and the project has no third-party archive dependency — so
/// this uses the system tools instead. The app is sandboxed, but it already runs
/// system binaries for the Kotatsu parser host, and the destination is always
/// inside the app's own container, which is what the sandbox permits.
nonisolated enum LocalArchive {
    struct ArchiveError: LocalizedError {
        let tool: String
        let message: String

        var errorDescription: String? {
            "Could not unpack the CBZ with \(tool). \(message)"
        }
    }

    private static let tools = ["/usr/bin/ditto", "/usr/bin/unzip"]

    static func extract(cbz: URL, to destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var failures: [String] = []

        for tool in tools where FileManager.default.isExecutableFile(atPath: tool) {
            do {
                _ = try await run(tool, arguments: arguments(for: tool, cbz: cbz, destination: destination))
                clean(destination)
                return
            } catch {
                failures.append("\(tool): \(error.localizedDescription)")
            }
        }

        throw ArchiveError(
            tool: "the system archive tools",
            message: failures.isEmpty
                ? "Neither ditto nor unzip is available."
                : failures.joined(separator: "; ")
        )
    }

    private static func arguments(for tool: String, cbz: URL, destination: URL) -> [String] {
        tool.hasSuffix("unzip")
            ? ["-o", "-qq", cbz.path, "-d", destination.path]
            : ["-x", "-k", cbz.path, destination.path]
    }

    /// Runs a tool to completion off the current actor. Nothing is awaited while it
    /// runs, so waiting here cannot deadlock.
    private static func run(_ executable: String, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let errorPipe = Pipe()
            let outputPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = outputPipe

            try process.run()
            process.waitUntilExit()

            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard process.terminationStatus == 0 else {
                throw ArchiveError(
                    tool: executable,
                    message: message.isEmpty ? "exit status \(process.terminationStatus)" : message
                )
            }
            return message
        }.value
    }

    /// Removes the metadata `ditto` copies out of the archive's resource fork.
    private static func clean(_ directory: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        var sidecars: [URL] = []
        for case let url as URL in enumerator {
            switch url.lastPathComponent {
            case "__MACOSX":
                sidecars.append(url)
            case ".DS_Store":
                try? FileManager.default.removeItem(at: url)
            default:
                break
            }
        }

        for url in sidecars {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
