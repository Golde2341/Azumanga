import SwiftData
import SwiftUI

@main
struct UzumakiApp: App {
    @State private var app: AppEnvironment

    init() {
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
