import SwiftUI

/// A responsive grid of manga cards with pagination and context actions.
struct MangaGrid: View {
    let items: [Manga]
    var favoriteIds: Set<String> = []
    var progressLabel: (Manga) -> String? = { _ in nil }
    var isLoadingMore: Bool = false
    var onReachEnd: (() -> Void)?

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 190), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(items) { manga in
                NavigationLink(value: manga) {
                    MangaCard(
                        manga: manga,
                        isFavorite: favoriteIds.contains(manga.id),
                        progressLabel: progressLabel(manga)
                    )
                }
                .buttonStyle(.plain)
                .onAppear {
                    if manga.id == items.last?.id {
                        onReachEnd?()
                    }
                }
            }
        }
        .padding(20)

        if isLoadingMore {
            ProgressView()
                .controlSize(.small)
                .padding(.bottom, 20)
        }
    }
}
