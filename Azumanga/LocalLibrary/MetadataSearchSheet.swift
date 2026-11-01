import SwiftUI

/// Searches every enabled source so an imported manga can take a real manga's
/// metadata and cover instead of having it typed out by hand.
struct MetadataSearchSheet: View {
    let services: Services
    let onPick: (Manga) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: GlobalSearchModel?
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Find Metadata")
                    .font(.headline)
                Text("Pick a manga to copy its title, author, description and cover.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()

            TextField("Search titles…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 10)

            Divider()

            content
        }
        .frame(width: 560, height: 520)
        .task {
            if model == nil { model = GlobalSearchModel(services: services) }
        }
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await model?.search(query: trimmed)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let model, !model.rows.isEmpty {
            List {
                ForEach(model.rows) { row in
                    Section(row.source.name) {
                        ForEach(row.results) { result in
                            Button { pick(result) } label: { resultRow(result) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.inset)
        } else if model?.isSearching == true {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Search a Title",
                systemImage: "magnifyingglass",
                description: Text("Results from your enabled sources appear here.")
            )
        }
    }

    private func resultRow(_ manga: Manga) -> some View {
        HStack(spacing: 10) {
            CoverImage(url: manga.coverURL, maxPixelSize: 120)
                .frame(width: 34, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(manga.title).lineLimit(1)
                if let author = manga.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func pick(_ manga: Manga) {
        Task {
            var full = manga
            // The search row can omit fields the detail request fills in.
            if let source = await services.registry.source(id: manga.sourceId),
               let details = try? await source.mangaDetails(id: manga.mangaId) {
                full = details
            }
            onPick(full)
            dismiss()
        }
    }
}
