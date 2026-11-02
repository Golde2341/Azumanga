import Foundation

/// Where the app keeps the user's manga files.
///
/// Everything the user might want to find in Finder — downloaded chapters and the
/// manga they imported themselves — lives under `Documents/azumanga`. In a sandboxed
/// app that is the app's own Documents folder, which is what macOS exposes as the
/// app's Documents.
nonisolated enum AppDirectories {
    static var documentsRoot: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("azumanga", isDirectory: true)
    }

    static func documents(_ name: String) -> URL {
        documentsRoot.appendingPathComponent(name, isDirectory: true)
    }
}
