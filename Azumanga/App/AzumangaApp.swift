import AppKit
import SwiftData
import SwiftUI

@main
struct AzumangaApp: App {
    @State private var app: AppEnvironment

    init() {
        // Reader windows are independent chapters, not documents: macOS must never
        // merge them into tabs. The tab bar is what comes down with the title bar in
        // native full screen, where only the traffic lights belong.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Move the old app-support/cache folders before any service opens them.
        AppDataMigration.run()
        _app = State(initialValue: AppEnvironment())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .withAppEnvironment(app)
        }
        .modelContainer(app.services.container)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Library") {
                    app.library.reload()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        // Reading lives in its own window: full screen behaves properly, the window
        // can be moved to another display, and several chapters can be open at once.
        WindowGroup("Reader", for: ReaderSession.self) { $session in
            if let session {
                ReaderContainerView(session: session)
                    .withAppEnvironment(app)
            }
        }
        .defaultSize(width: 1100, height: 850)
        // The page is the window: no title bar taking a strip of its own, so the reader's
        // floating controls can come and go without the page moving. The window still has
        // its traffic lights and can still be dragged by the top edge.
        .windowStyle(.hiddenTitleBar)
        // Reading is a session, not a document: reopening it at launch would drop the
        // reader back into whichever chapter was last open, which is not where anyone
        // wants to start. Opening a chapter is always an explicit act.
        .restorationBehavior(.disabled)
        .modelContainer(app.services.container)
    }
}

private extension View {
    /// Every scene needs the same environment; keeping it in one place means the
    /// reader window cannot drift from the main window.
    func withAppEnvironment(_ app: AppEnvironment) -> some View {
        self
            .environment(app)
            .environment(app.settings)
            .environment(app.services)
            .environment(app.library)
            .environment(app.discovery)
            .environment(app.sources)
            .environment(app.downloads)
            .environment(app.healthChecker)
            .environment(\.imagePipeline, app.services.images)
    }
}
