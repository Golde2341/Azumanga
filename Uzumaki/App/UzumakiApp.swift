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
                .environment(app)
                .environment(app.settings)
                .environment(app.services)
                .environment(app.library)
                .environment(app.discovery)
                .environment(app.sources)
                .environment(app.downloads)
                .environment(\.imagePipeline, app.services.images)
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
    }
}
