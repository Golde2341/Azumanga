import SwiftUI

/// Global search across every enabled source plus pinned sources.
struct GlobalSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: GlobalSearchModel
    @State private var query = ""
    @State private var path = NavigationPath()
    @FocusState private var searchFocused: Bool

    init(services: Services) {
        _model = State(initialValue: GlobalSearchModel(services: services))
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                searchBar
                Divider()
                content
            }
            .navigationDestination(for: Manga.self) { manga in
                MangaDetailView(manga: manga)
            }
        }
        .frame(width: 900, height: 650)
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                model.clear()
                return
            }

            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await model.search(query: trimmed)
        }
        .onAppear {
            searchFocused = true
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Global Search")
                    .font(.title2.weight(.semibold))
                Text("Searches every enabled source and any pinned source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Global Search", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)

            if model.isSearching {
                ProgressView()
                    .controlSize(.small)
            }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 3)
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "Global Search",
                systemImage: "magnifyingglass",
                description: Text("Find manga from all enabled sources, plus pinned sources even when they are disabled.")
            )
            .frame(maxHeight: .infinity)
        } else if model.isSearching && model.rows.isEmpty {
            ProgressView("Searching sources…")
                .frame(maxHeight: .infinity)
        } else if let error = model.errorMessage, model.rows.isEmpty {
            ContentUnavailableView(
                "Search Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
            .frame(maxHeight: .infinity)
        } else if model.rows.isEmpty && model.hasSearched {
            ContentUnavailableView(
                "No Results",
                systemImage: "magnifyingglass",
                description: Text("No source returned manga for “\(query)”.")
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(model.rows) { row in
                        sourceRow(row)
                    }
                }
                .padding(18)
            }
        }
    }

    private func sourceRow(_ row: GlobalSearchModel.SourceRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(row.source.name)
                    .font(.headline)

                if row.source.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }

                Spacer()

                Button {
                    Task { await model.togglePin(sourceID: row.source.id) }
                } label: {
                    Image(systemName: row.source.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(row.source.isPinned ? Color.accentColor : Color.secondary)
                .help(row.source.isPinned ? "Unpin source" : "Pin source")
            }

            if let error = row.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if row.results.isEmpty {
                Text("No results in this source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(row.results.prefix(20))) { manga in
                            mangaCard(manga, sourceID: row.source.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func mangaCard(_ manga: Manga, sourceID: String) -> some View {
        Button {
            model.noteOpened(sourceID: sourceID)
            path.append(manga)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                CoverImage(url: manga.coverURL, maxPixelSize: 256)
                    .frame(width: 92, height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text(manga.title)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 92, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(manga.title)
    }
}

