import Foundation

/// One-time move of the app's own on-disk folders to the new name.
///
/// The bundle identifier intentionally stays `lapepo.Uzumaki`: the sandbox
/// container, SwiftData store and preferences are keyed by it, so changing it
/// would strand the library and settings. Only the folders created inside that
/// container are renamed, and existing downloads/sources/caches are moved once.
enum AppDataMigration {
    static func run(fileManager: FileManager = .default) {
        migrate(
            in: .applicationSupportDirectory,
            from: "Uzumaki",
            to: "Azumanga",
            fileManager: fileManager
        )
        migrate(
            in: .cachesDirectory,
            from: "Uzumaki",
            to: "Azumanga",
            fileManager: fileManager
        )

        // Downloaded chapters and imported manga now live in Documents/azumanga.
        moveIntoDocuments("Downloads", fileManager: fileManager)
        moveIntoDocuments("LocalLibrary", fileManager: fileManager)
    }

    /// Moves a folder that an older build kept in Application Support into the
    /// Documents folder the app uses now. Does nothing once the move has happened.
    private static func moveIntoDocuments(_ name: String, fileManager: FileManager) {
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
              let documents = fileManager.urls(
                  for: .documentDirectory,
                  in: .userDomainMask
              ).first
        else { return }

        let old = support.appendingPathComponent("Azumanga/\(name)", isDirectory: true)
        let new = documents.appendingPathComponent("azumanga/\(name)", isDirectory: true)

        guard fileManager.fileExists(atPath: old.path),
              !fileManager.fileExists(atPath: new.path)
        else { return }

        try? fileManager.createDirectory(
            at: new.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.moveItem(at: old, to: new)
    }

    private static func migrate(
        in directory: FileManager.SearchPathDirectory,
        from oldName: String,
        to newName: String,
        fileManager: FileManager
    ) {
        guard let base = fileManager.urls(for: directory, in: .userDomainMask).first else { return }
        let old = base.appendingPathComponent(oldName, isDirectory: true)
        let new = base.appendingPathComponent(newName, isDirectory: true)
        guard fileManager.fileExists(atPath: old.path),
              !fileManager.fileExists(atPath: new.path)
        else { return }
        try? fileManager.moveItem(at: old, to: new)
    }
}
