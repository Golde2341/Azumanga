import Foundation
import SwiftUI

/// Backs the manga detail screen: full metadata, the chapter list and library
/// membership. Read state comes from `@Query` in the view so it updates live.
@MainActor
@Observable
final class MangaDetailModel {
    let manga: Manga
    private let services: Services

    var details: Manga
    var chapters: [Chapter] = []
    var isLoading = false
    var errorMessage: String?
    var isInLibrary = false

    init(manga: Manga, services: Services) {
        self.manga = manga
        self.details = manga
        self.services = services
        self.isInLibrary = (try? services.libraryStore.contains(sourceId: manga.sourceId, mangaId: manga.mangaId)) ?? false
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard let source = await services.registry.source(id: manga.sourceId) else {
            errorMessage = "The source for this manga is no longer available."
            return
        }

        async let detailsTask = try? source.mangaDetails(id: manga.mangaId)
        async let chaptersTask = try? source.chapters(mangaId: manga.mangaId)

        let (fetchedDetails, fetchedChapters) = await (detailsTask, chaptersTask)

        if let fetchedDetails {
            details = fetchedDetails
            if isInLibrary {
                _ = try? services.libraryStore.add(details)
            }
        }
        if let fetchedChapters {
            chapters = ordered(fetchedChapters)
        } else {
            errorMessage = "Could not load this manga. Check your connection and try again."
        }

        if fetchedDetails == nil && fetchedChapters == nil && errorMessage == nil {
            errorMessage = "Could not load this manga."
        }
    }

    /// Chapters presented oldest-first, with unnumbered entries last.
    func ordered(_ chapters: [Chapter]) -> [Chapter] {
        chapters.sorted { lhs, rhs in
            switch (lhs.number, rhs.number) {
            case let (l?, r?): l < r
            case (nil, nil): false
            case (nil, _): false
            case (_, nil): true
            }
        }
    }

    /// Where "Continue reading" should open, given the saved library pointer.
    func resumeChapter(lastReadChapterId: String?) -> Chapter? {
        if let lastReadChapterId,
           let match = chapters.first(where: { $0.chapterId == lastReadChapterId }) {
            return match
        }
        return chapters.first
    }

    // MARK: - Library

    func toggleLibrary() {
        do {
            if let entry = try services.libraryStore.entry(sourceId: manga.sourceId, mangaId: manga.mangaId) {
                try services.libraryStore.remove(entry)
                isInLibrary = false
            } else {
                try services.libraryStore.add(details)
                isInLibrary = true
            }
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    // MARK: - Read state

    func markRead(_ chapter: Chapter) {
        try? services.progressStore.markRead(chapter)
    }

    func markUnread(_ chapter: Chapter) {
        try? services.progressStore.markUnread(chapter)
    }

    func toggleRead(_ chapter: Chapter, isRead: Bool) {
        isRead ? markUnread(chapter) : markRead(chapter)
    }

    func recordOpened() {
        try? services.historyStore.record(manga: details, chapter: nil)
    }
}
