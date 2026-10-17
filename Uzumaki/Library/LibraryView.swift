import SwiftData
import SwiftUI

/// The user's saved manga, plus favourites, categories, reading history and
/// page bookmarks.
struct LibraryView: View {
    @Binding var path: NavigationPath
    @Environment(LibraryModel.self) private var library
    @Environment(\.openWindow) private var openWindow

    @State private var filter: Filter = .all
    @State private var selectedCategoryName: String?
    @State private var layout: Layout = .grid
    @State private var newCategoryName = ""
    @State private var showingNewCategory = false

    enum Filter: String, CaseIterable, Identifiable {
        case all
        case favorites
        case reading
        case bookmarks
        case history

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all: "All"
            case .favorites: "Favourites"
            case .reading: "Reading"
            case .bookmarks: "Bookmarks"
            case .history: "History"
            }
        }

        var systemImage: String {
            switch self {
            case .all: "books.vertical"
            case .favorites: "heart"
            case .reading: "book"
            case .bookmarks: "bookmark"
            case .history: "clock"
            }
        }
    }

    enum Layout: String, CaseIterable, Identifiable {
        case grid, list

        var id: String { rawValue }

        var displayName: String { self == .grid ? "Grid" : "List" }
    }

    var body: some View {
        Group {
            switch filter {
            case .bookmarks:
                bookmarkList
            case .history:
                historyList
            case .all, .favorites, .reading:
                libraryContent
            }
        }
        .navigationTitle("Library")
        .toolbar { toolbar }
        .navigationDestination(for: Manga.self) { manga in
            MangaDetailView(manga: manga)
        }
        .sheet(isPresented: $showingNewCategory) {
            newCategorySheet
        }
        .task {
            library.reload()
        }
    }

    // MARK: - Saved manga

    @ViewBuilder
    private var libraryContent: some View {
        if library.entries.isEmpty {
            ContentUnavailableView {
                Label("Your Library Is Empty", systemImage: "books.vertical")
            } description: {
                Text("Find something to read in Browse and tap Add to Library.")
            }
        } else if visibleEntries.isEmpty {
            ContentUnavailableView(
                "Nothing Here",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("No manga match the current filter.")
            )
        } else if layout == .grid {
            ScrollView {
                MangaGrid(
                    items: visibleEntries.map(\.manga),
                    favoriteIds: favoriteKeys,
                    progressLabel: progressLabel,
                    onOpen: { path.append($0) },
                    onForceTouch: continueReading
                )
            }
        } else {
            List {
                ForEach(visibleEntries) { entry in
                    NavigationLink(value: entry.manga) {
                        LibraryRow(entry: entry, progress: progressLabel(entry.manga))
                    }
                    .contextMenu { contextMenu(for: entry) }
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Bookmarks

    @ViewBuilder
    private var bookmarkList: some View {
        let bookmarks = library.bookmarks()
        if bookmarks.isEmpty {
            ContentUnavailableView(
                "No Bookmarks",
                systemImage: "bookmark",
                description: Text("Bookmark a page while reading and it will appear here.")
            )
        } else {
            List {
                ForEach(bookmarks) { bookmark in
                    Button {
                        openWindow(value: session(for: bookmark))
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(bookmark.mangaTitle) · page \(bookmark.pageIndex + 1)")
                                .lineLimit(1)
                            Text(bookmark.chapterTitle ?? bookmark.chapterId)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove Bookmark", role: .destructive) {
                            try? library.removeBookmark(bookmark)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func session(for bookmark: BookmarkRecord) -> ReaderSession {
        ReaderSession(
            manga: bookmark.manga,
            chapters: [],
            chapterId: bookmark.chapterId,
            startPageIndex: bookmark.pageIndex
        )
    }

    /// Force clicking a library cover opens the reader at the page that was being read.
    /// Returns whether there was progress to continue from; without it the force click
    /// falls through to the card's normal navigation.
    private func continueReading(_ manga: Manga) -> Bool {
        guard let entry = library.entry(for: manga),
              let chapterId = entry.lastReadChapterId
        else { return false }

        let chapter = Chapter(
            sourceId: manga.sourceId,
            mangaId: manga.mangaId,
            chapterId: chapterId,
            title: entry.lastReadChapterTitle,
            number: entry.lastReadChapterNumber
        )
        openWindow(value: ReaderSession(
            manga: manga,
            chapters: [],
            chapterId: chapterId,
            startPageIndex: library.progress(for: chapter)?.lastPageIndex
        ))
        return true
    }

    // MARK: - History

    @ViewBuilder
    private var historyList: some View {
        let history = library.history()
        if history.isEmpty {
            ContentUnavailableView(
                "No History",
                systemImage: "clock",
                description: Text("Manga you open will be listed here.")
            )
        } else {
            List {
                ForEach(history) { record in
                    NavigationLink(value: record.manga) {
                        HStack(spacing: 12) {
                            CoverImage(url: record.coverURL, maxPixelSize: 160)
                                .frame(width: 40, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.title).lineLimit(1)
                                Text(record.chapterTitle ?? record.visitedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .contextMenu {
                        Button("Remove from History", role: .destructive) {
                            try? library.removeHistory(record)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Data

    private var visibleEntries: [LibraryEntry] {
        var entries = library.entries
        if let selectedCategoryName,
           let category = library.categories.first(where: { $0.name == selectedCategoryName }) {
            entries = library.entries(in: category, sortedBy: library.sort)
        }
        switch filter {
        case .favorites:
            return entries.filter(\.isFavorite)
        case .reading:
            let reading = Set(library.recentlyRead(limit: 200).map { "\($0.sourceId):\($0.mangaId)" })
            return entries.filter { reading.contains($0.key) }
        default:
            return entries
        }
    }

    private var favoriteKeys: Set<String> {
        Set(library.entries.filter(\.isFavorite).map(\.key))
    }

    private func progressLabel(_ manga: Manga) -> String? {
        library.entry(for: manga)?.lastReadChapterTitle.map { "Last read: \($0)" }
    }

    @ViewBuilder
    private func contextMenu(for entry: LibraryEntry) -> some View {
        Button(entry.isFavorite ? "Remove from Favourites" : "Add to Favourites") {
            library.toggleFavorite(entry)
        }
        if !library.categories.isEmpty {
            Menu("Categorise") {
                ForEach(library.categories) { category in
                    Button {
                        var categories = entry.categories
                        if let index = categories.firstIndex(where: { $0.persistentModelID == category.persistentModelID }) {
                            categories.remove(at: index)
                        } else {
                            categories.append(category)
                        }
                        library.setCategories(categories, for: entry)
                    } label: {
                        if entry.categories.contains(where: { $0.persistentModelID == category.persistentModelID }) {
                            Label(category.name, systemImage: "checkmark")
                        } else {
                            Text(category.name)
                        }
                    }
                }
            }
        }
        Divider()
        Button("Remove from Library", role: .destructive) {
            library.remove(entry)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { filter in
                    Label(filter.displayName, systemImage: filter.systemImage).tag(filter)
                }
            }
            .frame(minWidth: 170)
        }

        ToolbarItem(placement: .automatic) {
            Picker("Category", selection: $selectedCategoryName) {
                Text("All Categories").tag(String?.none)
                ForEach(library.categories) { category in
                    Text(category.name).tag(String?.some(category.name))
                }
            }
            .frame(minWidth: 150)
        }

        ToolbarItem(placement: .automatic) {
            Picker("Sort", selection: Binding(
                get: { library.sort },
                set: { library.sort = $0; library.reload() }
            )) {
                ForEach(LibrarySort.allCases) { sort in
                    Text(sort.displayName).tag(sort)
                }
            }
            .frame(minWidth: 150)
        }

        ToolbarItem(placement: .automatic) {
            Picker("Layout", selection: $layout) {
                ForEach(Layout.allCases) { layout in
                    Image(systemName: layout == .grid ? "square.grid.2x2" : "list.bullet").tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 90)
        }

        ToolbarItem(placement: .automatic) {
            Button {
                showingNewCategory = true
            } label: {
                Label("New Category", systemImage: "folder.badge.plus")
            }
        }
    }

    private var newCategorySheet: some View {
        VStack(spacing: 16) {
            Text("New Category")
                .font(.headline)
            TextField("Name", text: $newCategoryName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            HStack {
                Button("Cancel") {
                    newCategoryName = ""
                    showingNewCategory = false
                }
                Button("Create") {
                    library.createCategory(named: newCategoryName)
                    newCategoryName = ""
                    showingNewCategory = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
    }
}

private struct LibraryRow: View {
    let entry: LibraryEntry
    let progress: String?

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: entry.coverURL, maxPixelSize: 160)
                .frame(width: 44, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.body)
                    .lineLimit(1)
                Text(progress ?? entry.author ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if entry.isFavorite {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
            }
        }
        .padding(.vertical, 2)
    }
}
