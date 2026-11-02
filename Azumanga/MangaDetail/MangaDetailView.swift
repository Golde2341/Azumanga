import AppKit
import SwiftData
import SwiftUI

/// Full metadata plus the chapter list, with library and read-state actions.
/// Reading progress is queried directly so marking a chapter read in the reader
/// is reflected here immediately.
struct MangaDetailView: View {
    let manga: Manga

    @Environment(Services.self) private var services
    @Environment(LibraryModel.self) private var library
    @Environment(DownloadsModel.self) private var downloads
    @Environment(\.openWindow) private var openWindow

    @Query private var progressRecords: [ReadingProgressRecord]

    @State private var model: MangaDetailModel?
    @State private var chapterSortAscending = true
    @State private var isSelectingChapters = false
    @State private var selectedChapterIDs: Set<String> = []
    @State private var lastSelectedChapterID: String?
    @State private var chapterRowFrames: [String: CGRect] = [:]
    @State private var marqueeSelectionBase: Set<String>?
    @State private var showingEditDetails = false
    /// Whether the pointer is over the "In Library" state, which reveals delete.
    @State private var isHoveringLibraryState = false
    /// A delete the user has asked for but not committed. Nothing is removed while
    /// this is set — the manga stays in the library and the button offers Undo. The
    /// delete only goes through when the user leaves this screen (back to the
    /// library, switching section), closes the window, or quits.
    @State private var pendingUndoManga: Manga?

    init(manga: Manga) {
        self.manga = manga
        let sourceId = manga.sourceId
        let mangaId = manga.mangaId
        let predicate: Predicate<ReadingProgressRecord> = #Predicate {
            $0.sourceId == sourceId && $0.mangaId == mangaId
        }
        let sort = [SortDescriptor(\ReadingProgressRecord.chapterNumber, order: .forward)]
        _progressRecords = Query(filter: predicate, sort: sort)
    }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(manga.title)
        .task {
            if model == nil {
                model = MangaDetailModel(manga: manga, services: services)
                model?.recordOpened()
            }
            await model?.load()
        }
        .sheet(isPresented: $showingEditDetails) {
            ImportMangaSheet(services: services, library: library, editingMangaId: manga.mangaId)
        }
        .onDisappear {
            // Going back to the library, switching section, or closing the window
            // ends the undo opportunity.
            commitPendingDelete()
        }
        .task {
            // Quitting commits it too.
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.willTerminateNotification
            ) {
                commitPendingDelete()
            }
        }
        .onChange(of: showingEditDetails) { _, isPresented in
            guard !isPresented else { return }
            // The edit changed the metadata on disk; pick it back up.
            library.reload()
            Task { await model?.load() }
        }
    }

    @ViewBuilder
    private func content(_ model: MangaDetailModel) -> some View {
        let chapters = visibleChapters(model)
        let progressByChapter = Dictionary(
            progressRecords.map { ($0.chapterId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let downloadsByKey = Dictionary(
            downloads.records.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        List {
            Section {
                header(model)
            }

            if model.isLoading && model.chapters.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading chapters…")
                        Spacer()
                    }
                }
            } else if model.chapters.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Chapters",
                        systemImage: "book.closed",
                        description: Text("This source returned no chapters in this language.")
                    )
                }
            } else {
                Section {
                    ForEach(chapters) { chapter in
                        let isSelected = selectedChapterIDs.contains(chapter.chapterId)
                        let progress = progressByChapter[chapter.chapterId]
                        let chapterIsRead = progress?.status == .completed
                        let downloadState = downloadsByKey[downloadKey(chapter)]?.state

                        Button {
                            if isSelectingChapters {
                                selectChapter(
                                    chapter,
                                    model: model,
                                    extendRange: NSEvent.modifierFlags
                                        .intersection([.command, .shift])
                                        .isEmpty == false
                                )
                            } else {
                                openReader(session(for: chapter, model: model))
                            }
                        } label: {
                            HStack(spacing: 10) {
                                if isSelectingChapters {
                                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                        .font(.title3)
                                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                }

                                ChapterRow(
                                    chapter: chapter,
                                    isRead: chapterIsRead,
                                    progress: progress,
                                    downloadState: downloadState
                                )
                            }
                            .contentShape(Rectangle())
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: ChapterRowFramesKey.self,
                                        value: [
                                            chapter.chapterId: geometry.frame(
                                                in: .named("chapterList")
                                            )
                                        ]
                                    )
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                        .contextMenu {
                            Button(chapterIsRead ? "Mark as Unread" : "Mark as Read") {
                                model.toggleRead(chapter, isRead: chapterIsRead)
                            }
                            Divider()
                            downloadActions(for: chapter, model: model)
                        }
                    }
                } header: {
                    HStack(spacing: 10) {
                        Text("\(model.chapters.count) Chapters")
                        Spacer()
                        Button {
                            chapterSortAscending.toggle()
                        } label: {
                            Label(
                                chapterSortAscending ? "Oldest First" : "Newest First",
                                systemImage: chapterSortAscending ? "arrow.up" : "arrow.down"
                            )
                            .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        if isSelectingChapters {
                            Text("Selecting")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tint)
                        } else {
                            Button {
                                isSelectingChapters = true
                                selectedChapterIDs.removeAll()
                                lastSelectedChapterID = nil
                                marqueeSelectionBase = nil
                            } label: {
                                Label("Select", systemImage: "checklist")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Select chapters. Drag across rows, or Shift/Command-click to select a range.")
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .coordinateSpace(name: "chapterList")
        .onPreferenceChange(ChapterRowFramesKey.self) { frames in
            chapterRowFrames = frames
        }
        .simultaneousGesture(marqueeGesture(model))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelectingChapters {
                selectionBar(model)
            }
        }
        .toolbar { toolbar(model) }
        .alert("Something Went Wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Read state

    private func progress(for chapter: Chapter) -> ReadingProgressRecord? {
        progressRecords.first { $0.chapterId == chapter.chapterId }
    }

    private var readCount: Int {
        progressRecords.count { $0.status == .completed }
    }

    private func session(for chapter: Chapter, model: MangaDetailModel) -> ReaderSession {
        ReaderSession(manga: model.details, chapters: model.chapters, chapterId: chapter.chapterId)
    }

    /// Reading opens in its own window rather than pushing onto this stack.
    private func openReader(_ session: ReaderSession) {
        openWindow(value: session)
    }

    private func visibleChapters(_ model: MangaDetailModel) -> [Chapter] {
        chapterSortAscending
            ? model.chapters
            : Array(model.chapters.reversed())
    }

    private func downloadKey(_ chapter: Chapter) -> String {
        "\(chapter.sourceId):\(chapter.mangaId):\(chapter.chapterId)"
    }

    // MARK: - Batch read state

    private func selectChapter(
        _ chapter: Chapter,
        model: MangaDetailModel,
        extendRange: Bool
    ) {
        if extendRange, let anchorID = lastSelectedChapterID {
            let chapters = visibleChapters(model)
            if let anchor = chapters.firstIndex(where: { $0.chapterId == anchorID }),
               let clicked = chapters.firstIndex(where: { $0.chapterId == chapter.chapterId }) {
                let range = min(anchor, clicked)...max(anchor, clicked)
                selectedChapterIDs.formUnion(chapters[range].map(\.chapterId))
                lastSelectedChapterID = chapter.chapterId
                return
            }
        }

        toggleSelection(of: chapter)
        lastSelectedChapterID = chapter.chapterId
    }

    private func marqueeGesture(_ model: MangaDetailModel) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("chapterList"))
            .onChanged { value in
                guard isSelectingChapters else { return }
                if marqueeSelectionBase == nil {
                    marqueeSelectionBase = selectedChapterIDs
                }

                let chapters = visibleChapters(model)
                guard let start = chapterIndex(near: value.startLocation.y, in: chapters),
                      let end = chapterIndex(near: value.location.y, in: chapters)
                else { return }

                let range = min(start, end)...max(start, end)
                selectedChapterIDs = (marqueeSelectionBase ?? [])
                    .union(chapters[range].map(\.chapterId))
                lastSelectedChapterID = chapters[range.upperBound].chapterId
            }
            .onEnded { _ in
                marqueeSelectionBase = nil
            }
    }

    private func chapterIndex(near y: CGFloat, in chapters: [Chapter]) -> Int? {
        guard let nearest = chapterRowFrames.min(by: {
            abs($0.value.midY - y) < abs($1.value.midY - y)
        }) else { return nil }
        return chapters.firstIndex { $0.chapterId == nearest.key }
    }

    private func toggleSelection(of chapter: Chapter) {
        if selectedChapterIDs.contains(chapter.chapterId) {
            selectedChapterIDs.remove(chapter.chapterId)
        } else {
            selectedChapterIDs.insert(chapter.chapterId)
        }
    }

    private func selectionBar(_ model: MangaDetailModel) -> some View {
        HStack(spacing: 10) {
            Text(selectedChapterIDs.isEmpty
                 ? "Select chapters"
                 : "\(selectedChapterIDs.count) selected")
                .font(.callout.weight(.medium))
                .foregroundStyle(selectedChapterIDs.isEmpty ? .secondary : .primary)

            Spacer()

            Button("Select All") {
                selectedChapterIDs = Set(model.chapters.map(\.chapterId))
                lastSelectedChapterID = nil
            }
            .disabled(model.chapters.isEmpty)

            Button("Clear") {
                selectedChapterIDs.removeAll()
                lastSelectedChapterID = nil
            }
            .disabled(selectedChapterIDs.isEmpty)

            Divider()
                .frame(height: 20)

            Button("Mark Read") {
                markSelectedChapters(read: true, model: model)
            }
            .buttonStyle(.bordered)
            .disabled(selectedChapterIDs.isEmpty)

            Button("Mark Unread") {
                markSelectedChapters(read: false, model: model)
            }
            .buttonStyle(.bordered)
            .disabled(selectedChapterIDs.isEmpty)

            Button("Done") {
                isSelectingChapters = false
                selectedChapterIDs.removeAll()
                lastSelectedChapterID = nil
                marqueeSelectionBase = nil
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func markSelectedChapters(read: Bool, model: MangaDetailModel) {
        let chapters = model.chapters.filter {
            selectedChapterIDs.contains($0.chapterId)
        }
        guard !chapters.isEmpty else { return }
        if read {
            model.markRead(chapters)
        } else {
            model.markUnread(chapters)
        }
        selectedChapterIDs.removeAll()
        lastSelectedChapterID = nil
        marqueeSelectionBase = nil
    }

    // MARK: - Downloads

    @ViewBuilder
    private func downloadActions(for chapter: Chapter, model: MangaDetailModel) -> some View {
        if chapter.externalURL != nil {
            EmptyView()
        } else if let record = downloads.record(for: chapter) {
            switch record.state {
            case .completed:
                Button("Delete Download", role: .destructive) { downloads.delete(record) }
            case .downloading, .queued:
                Button("Pause Download") { downloads.pause(record) }
                Button("Cancel Download", role: .destructive) { downloads.cancel(record) }
            case .paused, .failed:
                Button("Resume Download") { downloads.resume(record) }
                Button("Delete Download", role: .destructive) { downloads.delete(record) }
            }
        } else {
            Button("Download Chapter") {
                downloads.enqueue(downloads.job(for: chapter, manga: model.details))
            }
        }
    }

    private func downloadChapters(_ chapters: [Chapter], model: MangaDetailModel) {
        for chapter in chapters where chapter.externalURL == nil {
            downloads.enqueue(downloads.job(for: chapter, manga: model.details))
        }
    }

    // MARK: - Header

    private func header(_ model: MangaDetailModel) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Group {
                if model.isLoading && model.chapters.isEmpty {
                    // The Kotatsu host serializes requests; starting the cover image
                    // here can put a large poster ahead of the chapter/details call.
                    // Show the placeholder until the episode list is on its way.
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                } else {
                    CoverImage(url: model.details.coverURL, maxPixelSize: 640)
                }
            }
            .frame(width: 150, height: 225)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 8) {
                Text(model.details.title)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if let authorLine = model.details.authorLine {
                    Label(authorLine, systemImage: "person")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    if model.details.status != .unknown {
                        Badge(text: model.details.status.displayName)
                    }
                    if let year = model.details.year {
                        Badge(text: String(year))
                    }
                    if model.details.contentRating != .safe {
                        Badge(text: model.details.contentRating.displayName, tint: .orange)
                    }
                    if !model.chapters.isEmpty {
                        Badge(text: "\(readCount)/\(model.chapters.count) read", tint: .green)
                    }
                }

                if !model.details.genres.isEmpty {
                    Text(model.details.genres.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 10) {
                    if let resume = model.resumeChapter(lastReadChapterId: entry?.lastReadChapterId) {
                        Button {
                            openReader(session(for: resume, model: model))
                        } label: {
                            Label(
                                progress(for: resume) != nil ? "Continue Reading" : "Start Reading",
                                systemImage: "book.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    // One button for the whole membership cycle. Every label is laid
                    // out at once, so the button keeps its exact shape and the labels
                    // cross-fade into one another: Add → In Library → Delete → Undo.
                    Button {
                        performLibraryAction()
                    } label: {
                        ZStack {
                            Label("Add to Library", systemImage: "plus.circle")
                                .opacity(libraryButtonState == .add ? 1 : 0)
                            Label("In Library", systemImage: "checkmark.circle.fill")
                                .opacity(libraryButtonState == .inLibrary ? 1 : 0)
                            Label("Delete", systemImage: "trash")
                                .opacity(libraryButtonState == .delete ? 1 : 0)
                            Label("Undo", systemImage: "arrow.uturn.backward")
                                .opacity(libraryButtonState == .undo ? 1 : 0)
                        }
                        .animation(.easeInOut(duration: 0.14), value: libraryButtonState)
                    }
                    .tint(libraryButtonState == .delete ? .red : nil)
                    .accessibilityLabel(libraryButtonState.accessibilityLabel)
                    .help(libraryButtonState.accessibilityLabel)
                    .onHover { isHoveringLibraryState = $0 }

                    if let entry {
                        Button {
                            library.toggleFavorite(entry)
                        } label: {
                            Label("Favourite", systemImage: entry.isFavorite ? "heart.fill" : "heart")
                        }
                        .tint(entry.isFavorite ? .pink : nil)
                    }

                    if manga.sourceId == LocalLibrarySource.sourceId {
                        Button {
                            showingEditDetails = true
                        } label: {
                            Label("Edit Details", systemImage: "pencil")
                        }
                    }

                    if let webURL = model.details.webURL {
                        Link(destination: webURL) {
                            Label("Open Source", systemImage: "arrow.up.right.square")
                        }
                    }
                }

                if let description = model.details.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private var entry: LibraryEntry? {
        library.entry(for: manga)
    }

    // MARK: - Library membership

    private enum LibraryButtonState {
        case add
        case inLibrary
        case delete
        case undo

        var accessibilityLabel: String {
            switch self {
            case .add: "Add to Library"
            case .inLibrary: "In Library"
            case .delete: "Delete from Library"
            case .undo: "Undo delete"
            }
        }
    }

    private var libraryButtonState: LibraryButtonState {
        if pendingUndoManga != nil { return .undo }
        guard model?.isInLibrary == true else { return .add }
        return isHoveringLibraryState ? .delete : .inLibrary
    }

    private func performLibraryAction() {
        switch libraryButtonState {
        case .add:
            model?.toggleLibrary()
            library.reload()
        case .inLibrary, .delete:
            deleteFromLibrary()
        case .undo:
            undoDelete()
        }
    }

    /// Asks to delete the manga. Nothing actually happens yet: the entry stays in
    /// the library and the button turns into Undo, so the delete is only confirmed by
    /// leaving this screen, closing the window, or quitting.
    private func deleteFromLibrary() {
        guard pendingUndoManga == nil else { return }
        pendingUndoManga = manga
    }

    private func undoDelete() {
        pendingUndoManga = nil
    }

    /// Confirms a pending delete: the library entry goes, then an import's files and
    /// its cached cover. Called when the undo opportunity ends.
    private func commitPendingDelete() {
        guard let pending = pendingUndoManga else { return }
        pendingUndoManga = nil

        if let entry = library.entry(for: pending) {
            library.remove(entry)
        }
        model?.isInLibrary = false

        // The folder removal is synchronous so it still happens when the app is
        // quitting; the cache eviction is best-effort.
        if pending.sourceId == LocalLibrarySource.sourceId {
            services.localLibrary.deleteManga(id: pending.mangaId)
        }
        if let cover = pending.coverURL {
            Task { await services.images.evict(url: cover) }
        }

        library.reload()
    }

    @ToolbarContentBuilder
    private func toolbar(_ model: MangaDetailModel) -> some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Menu {
                Button("Download Unread Chapters") {
                    let read = Set(
                        progressRecords.lazy
                            .filter { $0.status == .completed }
                            .map(\.chapterId)
                    )
                    let unread = model.chapters.filter { !read.contains($0.chapterId) }
                    downloadChapters(unread, model: model)
                }
                Button("Download All Chapters") {
                    downloadChapters(model.chapters, model: model)
                }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .disabled(model.chapters.isEmpty)
        }

        ToolbarItem(placement: .automatic) {
            Button {
                Task { await model.load() }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoading)
        }
    }
}

/// Chapter rows report their frames in the list's coordinate space so a marquee
/// drag can turn the rows it crosses into a contiguous selection.
private struct ChapterRowFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct ChapterRow: View {
    let chapter: Chapter
    let isRead: Bool
    let progress: ReadingProgressRecord?
    let downloadState: DownloadState?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isRead ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isRead ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(chapter.subtitleLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let progress, progress.status == .reading, progress.totalPages > 0 {
                Text("\(progress.lastPageIndex + 1)/\(progress.totalPages)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if chapter.externalURL != nil {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
                    .help("Hosted externally")
            }

            switch downloadState {
            case .completed:
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                    .help("Downloaded")
            case .downloading, .queued:
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                    .help("Downloading")
            case .paused:
                Image(systemName: "pause.circle")
                    .foregroundStyle(.secondary)
                    .help("Download paused")
            case .failed:
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help("Download failed")
            case nil:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }
}

struct Badge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}
