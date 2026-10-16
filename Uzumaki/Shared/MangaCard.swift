import SwiftUI

extension Manga {
    var authorLine: String? {
        switch (author, artist) {
        case let (author?, artist?) where author != artist:
            "\(author) · \(artist)"
        case let (author?, _):
            author
        case let (nil, artist?):
            artist
        default:
            nil
        }
    }

    var subtitleLine: String? {
        var parts: [String] = []
        if let authorLine { parts.append(authorLine) }
        if status != .unknown { parts.append(status.displayName) }
        if let year { parts.append(String(year)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension Chapter {
    var subtitleLine: String {
        var parts: [String] = []
        if !displayNumber.isEmpty { parts.append("Ch. \(displayNumber)") }
        if let scanlator { parts.append(scanlator) }
        if let publishedAt { parts.append(publishedAt.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }
}

/// Reusable manga card used by both Browse and Library.
struct MangaCard: View {
    let manga: Manga
    var isFavorite: Bool = false
    var progressLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(url: manga.coverURL)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.pink)
                            .padding(5)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(6)
                    }
                }

            Text(manga.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let progressLabel {
                Text(progressLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let subtitle = manga.subtitleLine {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}
