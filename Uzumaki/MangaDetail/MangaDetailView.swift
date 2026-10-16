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

    @Query private var progressRecords: [ReadingProgressRecord]

    @State private var model: MangaDetailModel?
    @State private var chapterSortAscending = true

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
        .navigationDestination(for: ReaderSession.self) { session in
            ReaderContainerView(session: session)
        }
        .task {
            if model == nil {
                model = MangaDetailModel(manga: manga, services: services)
                model?.recordOpened()
            }
            await model?.load()
        }
    }

    @ViewBuilder
    private func content(_ model: MangaDetailModel) -> some View {
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
                    ForEach(visibleChapters(model)) { chapter in
                        NavigationLink(value: session(for: chapter, model: model)) {
                            ChapterRow(
                                chapter: chapter,
                                isRead: isRead(chapter),
                                progress: progress(for: chapter),
                                downloadState: downloads.state(of: chapter)
                            )
                        }
                        .contextMenu {
                            Button(isRead(chapter) ? "Mark as Unread" : "Mark as Read") {
                                model.toggleRead(chapter, isRead: isRead(chapter))
                            }
                            Divider()
                            downloadActions(for: chapter, model: model)
                        }
                    }
                } header: {
                    HStack {
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
                    }
                }
            }
        }
        .listStyle(.inset)
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

    private func isRead(_ chapter: Chapter) -> Bool {
        progress(for: chapter)?.status == .completed
    }

    private var readCount: Int {
        progressRecords.count { $0.status == .completed }
    }

    private func session(for chapter: Chapter, model: MangaDetailModel) -> ReaderSession {
        ReaderSession(manga: model.details, chapters: model.chapters, chapterId: chapter.chapterId)
    }

    private func visibleChapters(_ model: MangaDetailModel) -> [Chapter] {
        let ordered = model.ordered(model.chapters)
        return chapterSortAscending ? ordered : ordered.reversed()
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
            CoverImage(url: model.details.coverURL, maxPixelSize: 640)
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
                        NavigationLink(value: session(for: resume, model: model)) {
                            Label(
                                progress(for: resume) != nil ? "Continue Reading" : "Start Reading",
                                systemImage: "book.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button {
                        model.toggleLibrary()
                        library.reload()
                    } label: {
                        Label(
                            model.isInLibrary ? "In Library" : "Add to Library",
                            systemImage: model.isInLibrary ? "checkmark.circle.fill" : "plus.circle"
                        )
                    }

                    if let entry {
                        Button {
                            library.toggleFavorite(entry)
                        } label: {
                            Label("Favourite", systemImage: entry.isFavorite ? "heart.fill" : "heart")
                        }
                        .tint(entry.isFavorite ? .pink : nil)
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

    @ToolbarContentBuilder
    private func toolbar(_ model: MangaDetailModel) -> some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Menu {
                Button("Download Unread Chapters") {
                    let unread = model.chapters.filter { !isRead($0) }
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
