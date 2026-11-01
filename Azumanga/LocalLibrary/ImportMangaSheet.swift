import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Adds a manga made of local CBZ files — one manga, one chapter per file — and
/// edits an import that already exists.
///
/// The same sheet does both: in edit mode the file picker is hidden and the chapter
/// list is the one already on disk.
struct ImportMangaSheet: View {
    let services: Services
    let library: LibraryModel
    /// Set when editing an existing local manga; `nil` imports new files.
    var editingMangaId: String?

    @Environment(\.dismiss) private var dismiss

    @State private var files: [URL] = []
    @State private var chapters: [LocalChapterEntry] = []
    @State private var title = ""
    @State private var author = ""
    @State private var artist = ""
    @State private var summary = ""
    @State private var genres: [String] = []
    @State private var status: PublicationStatus = .unknown
    @State private var cover: LocalCoverChoice?
    @State private var useFirstPageAsCover = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showingFileImporter = false
    @State private var showingCoverImporter = false
    @State private var showingMetadataSearch = false
    @State private var hasLoaded = false
    /// Chosen files are copied here as soon as they are picked. A dropped or
    /// imported URL is only guaranteed readable while its security scope is fresh,
    /// and the library copy happens later, when the import is saved.
    @State private var staging: URL?

    private var isEditing: Bool { editingMangaId != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 620, height: 640)
        .task { load() }
        .onDisappear {
            if let staging { try? FileManager.default.removeItem(at: staging) }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.zip, .pdf, .data],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result { addFiles(urls) }
        }
        .fileImporter(
            isPresented: $showingCoverImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                cover = .file(url)
                useFirstPageAsCover = false
            }
        }
        .sheet(isPresented: $showingMetadataSearch) {
            MetadataSearchSheet(services: services) { manga in
                apply(metadata: manga)
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text(isEditing ? "Edit Details" : "Add Manga")
                .font(.headline)
            Spacer()
            Button("Search Metadata…") { showingMetadataSearch = true }
            Button("Cancel") { dismiss() }
        }
        .padding()
    }

    private var content: some View {
        List {
            if !isEditing {
                Section("CBZ or PDF Files") {
                    dropZone
                    ForEach(files, id: \.self) { url in
                        Text(LocalLibraryStore.chapterTitle(from: url.lastPathComponent))
                            .lineLimit(1)
                    }
                    .onMove(perform: moveFiles)
                }
            }

            Section("Details") {
                TextField("Title", text: $title)
                TextField("Author", text: $author)
                TextField("Artist", text: $artist)
                Picker("Status", selection: $status) {
                    ForEach(PublicationStatus.allCases, id: \.self) { status in
                        Text(status.displayName).tag(status)
                    }
                }
                if !genres.isEmpty {
                    LabeledContent("Genres", value: genres.joined(separator: ", "))
                }
            }

            Section("Description") {
                TextEditor(text: $summary)
                    .font(.body)
                    .frame(minHeight: 90)
            }

            Section("Cover") {
                coverRow
            }

            if isEditing || !chapters.isEmpty {
                Section("Chapters") {
                    ForEach(chapters) { chapter in
                        Text(chapter.title).lineLimit(1)
                    }
                    .onMove(perform: moveChapters)
                    if chapters.isEmpty {
                        Text("No chapters yet.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var dropZone: some View {
        Button {
            showingFileImporter = true
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.title2)
                Text("Drop CBZ or PDF files here, or click to choose")
                    .font(.callout)
                Text("Each file becomes one chapter, in name order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            addFiles(urls)
            return true
        }
    }

    private var coverRow: some View {
        HStack(spacing: 14) {
            Group {
                if let coverURL = coverPreviewURL {
                    CoverImage(url: coverURL, maxPixelSize: 240)
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 76, height: 108)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Button("Choose Image…") { showingCoverImporter = true }
                if isEditing || !files.isEmpty {
                    Toggle("Use the first page", isOn: $useFirstPageAsCover)
                        .onChange(of: useFirstPageAsCover) { _, isOn in
                            if isOn { cover = nil }
                        }
                }
                if cover != nil {
                    Button("Clear Cover") { cover = .removed }
                        .foregroundStyle(.red)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            if isWorking { ProgressView().controlSize(.small) }
            Button(isEditing ? "Save" : "Import") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking)
        }
        .padding()
    }

    // MARK: - Derived state

    /// What the cover preview should show right now.
    private var coverPreviewURL: URL? {
        switch cover {
        case let .file(url): url
        case let .remote(url): url
        case .removed, .none:
            useFirstPageAsCover ? nil : existingCoverURL
        }
    }

    private var existingCoverURL: URL? {
        guard let editingMangaId else { return nil }
        return services.localLibrary.coverURL(mangaId: editingMangaId)
    }

    // MARK: - Loading and editing

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let editingMangaId else { return }

        if let metadata = services.localLibrary.metadata(editingMangaId) {
            title = metadata.title
            author = metadata.author ?? ""
            artist = metadata.artist ?? ""
            summary = metadata.description ?? ""
            genres = metadata.genres
            status = metadata.status
        }
        chapters = services.localLibrary.chapters(editingMangaId)
    }

    private func addFiles(_ urls: [URL]) {
        // Ignore anything already chosen, comparing the original names.
        let new = urls.filter { url in
            !files.contains { $0.lastPathComponent == url.lastPathComponent }
        }
        guard !new.isEmpty else { return }

        files.append(contentsOf: stage(new))
        files = LocalLibraryStore.naturalSorted(files)
        rebuildChaptersFromFiles()
    }

    private func stage(_ urls: [URL]) -> [URL] {
        guard let directory = stagingDirectory() else { return [] }

        return urls.compactMap { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let destination = Self.uniqueURL(in: directory, preferredName: url.lastPathComponent)
            guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else { return nil }
            return destination
        }
    }

    private func stagingDirectory() -> URL? {
        if let staging { return staging }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AzumangaImport-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )) != nil else { return nil }

        staging = directory
        return directory
    }

    private static func uniqueURL(in directory: URL, preferredName: String) -> URL {
        let base = (preferredName as NSString).deletingPathExtension
        let fileExtension = (preferredName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(preferredName)
        var index = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = fileExtension.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(fileExtension)"
            candidate = directory.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }

    private func rebuildChaptersFromFiles() {
        let previous = Dictionary(chapters.map { ($0.fileName, $0.id) }, uniquingKeysWith: { first, _ in first })
        chapters = files.enumerated().map { index, url in
            LocalChapterEntry(
                id: previous[url.lastPathComponent] ?? UUID().uuidString,
                fileName: url.lastPathComponent,
                title: LocalLibraryStore.chapterTitle(from: url.lastPathComponent),
                number: Double(index + 1),
                order: index
            )
        }

        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let first = files.first {
            title = LocalLibraryStore.chapterTitle(from: first.lastPathComponent)
        }
    }

    private func moveFiles(from source: IndexSet, to destination: Int) {
        files.move(fromOffsets: source, toOffset: destination)
        rebuildChaptersFromFiles()
    }

    private func moveChapters(from source: IndexSet, to destination: Int) {
        chapters.move(fromOffsets: source, toOffset: destination)
        chapters = chapters.enumerated().map { index, chapter in
            var chapter = chapter
            chapter.order = index
            chapter.number = Double(index + 1)
            return chapter
        }
    }

    private func apply(metadata manga: Manga) {
        title = manga.title
        if let value = manga.author { author = value }
        if let value = manga.artist { artist = value }
        if let value = manga.description { summary = value }
        if !manga.genres.isEmpty { genres = manga.genres }
        if manga.status != .unknown { status = manga.status }
        if let url = manga.coverURL {
            cover = .remote(url)
            useFirstPageAsCover = false
        }
    }

    // MARK: - Saving

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            errorMessage = "Give the manga a title."
            return
        }
        guard isEditing || !files.isEmpty else {
            errorMessage = "Choose at least one CBZ file."
            return
        }

        errorMessage = nil
        isWorking = true

        Task {
            do {
                let manga = try await persist(title: trimmedTitle)
                library.add(manga)
                library.reload()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isWorking = false
            }
        }
    }

    private func persist(title trimmedTitle: String) async throws -> Manga {
        let description = Self.nilIfBlank(summary)
        let authorValue = Self.nilIfBlank(author)
        let artistValue = Self.nilIfBlank(artist)

        if let editingMangaId {
            var manga = try services.localLibrary.updateManga(
                mangaId: editingMangaId,
                title: trimmedTitle,
                description: description,
                author: authorValue,
                artist: artistValue,
                genres: genres,
                status: status,
                cover: coverSourceForSave(),
                chapters: chapters
            )

            if case let .remote(url) = cover {
                let name = try await downloadCover(url, mangaId: editingMangaId)
                try services.localLibrary.setCoverFileName(name, mangaId: editingMangaId)
                manga.coverURL = services.localLibrary.coverURL(mangaId: editingMangaId)
            }
            return manga
        }

        let created = try services.localLibrary.createManga(
            title: trimmedTitle,
            description: description,
            author: authorValue,
            artist: artistValue,
            genres: genres,
            status: status,
            cover: usesRemoteCover ? nil : coverSourceForSave(),
            files: files
        )
        var manga = created.manga

        if case let .remote(url) = cover {
            let name = try await downloadCover(url, mangaId: manga.mangaId)
            try services.localLibrary.setCoverFileName(name, mangaId: manga.mangaId)
            manga.coverURL = services.localLibrary.coverURL(mangaId: manga.mangaId)
        } else if useFirstPageAsCover, let first = created.chapters.first {
            let pages = try await services.localLibrary.pageURLs(
                mangaId: manga.mangaId,
                chapterId: first.id
            )
            if let page = pages.first {
                let name = try services.localLibrary.copyCover(from: page, mangaId: manga.mangaId)
                try services.localLibrary.setCoverFileName(name, mangaId: manga.mangaId)
                manga.coverURL = services.localLibrary.coverURL(mangaId: manga.mangaId)
            }
        }

        return manga
    }

    private var usesRemoteCover: Bool {
        if case .remote = cover { return true }
        return false
    }

    private func coverSourceForSave() -> LocalCoverSource? {
        switch cover {
        case let .file(url): .file(url)
        case .removed: .remove
        case .remote: nil
        case .none: isEditing ? .keep : nil
        }
    }

    /// Fetches a search result's cover through the image pipeline, so host-backed
    /// covers resolve the same way they do everywhere else in the app.
    private func downloadCover(_ url: URL, mangaId: String) async throws -> String {
        let image = try await services.images.image(for: url, maxPixelSize: 1200)
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.9]
        ) else {
            throw MangaSourceError.notFound
        }
        return try services.localLibrary.writeCover(data, fileExtension: "jpg", mangaId: mangaId)
    }

    private static func nilIfBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
