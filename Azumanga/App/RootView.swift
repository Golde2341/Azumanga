import AppKit
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case library
    case browse
    case downloads
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Library"
        case .browse: "Browse"
        case .downloads: "Downloads"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .library: "books.vertical"
        case .browse: "safari"
        case .downloads: "arrow.down.circle"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var app

    @AppStorage("hasCompletedWelcome") private var hasCompletedWelcome = false
    @State private var selection: SidebarItem? = .library
    @State private var libraryPath = NavigationPath()
    @State private var showingGlobalSearch = false

    private var welcomeBinding: Binding<Bool> {
        Binding(
            get: { !hasCompletedWelcome },
            set: { presented in
                if !presented { hasCompletedWelcome = true }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Button {
                    showingGlobalSearch = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                        Text("Global Search")
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 3)
                .padding(8)

                List(SidebarItem.allCases, selection: $selection) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            switch selection {
            case .library:
                NavigationStack(path: $libraryPath) { LibraryView(path: $libraryPath) }
            case .browse:
                NavigationStack { BrowseView() }
            case .downloads:
                NavigationStack { DownloadsView() }
            case .settings:
                SettingsView()
            case nil:
                ContentUnavailableView(
                    "Nothing Selected",
                    systemImage: "sidebar.left",
                    description: Text("Choose a section from the sidebar.")
                )
            }
        }
        .sheet(isPresented: welcomeBinding) {
            WelcomeView {
                hasCompletedWelcome = true
            }
            .environment(app)
        }
        .sheet(isPresented: $showingGlobalSearch) {
            GlobalSearchView(services: app.services)
        }
        .task {
            await app.bootstrap()
        }
        .task {
            // Stop the parser host when the app goes away. It exits on stdin EOF
            // too, but relying on that leaves JVMs lingering after a kill.
            for await _ in NotificationCenter.default.notifications(named: NSApplication.willTerminateNotification) {
                await app.services.kotatsuHost?.shutdown()
                break
            }
        }
    }
}

#Preview {
    RootView()
        .environment(AppEnvironment(container: try! PersistenceContainer.make(inMemory: true)))
        .environment(\.imagePipeline, AppImages.shared)
}
