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

    @State private var selection: SidebarItem? = .library

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            switch selection {
            case .library:
                NavigationStack { LibraryView() }
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
        .task {
            await app.bootstrap()
        }
    }
}

#Preview {
    RootView()
        .environment(AppEnvironment(container: try! PersistenceContainer.make(inMemory: true)))
        .environment(\.imagePipeline, AppImages.shared)
}
