import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Azumanga

@Suite("Local library")
struct LocalLibraryTests {
    private func makeTempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AzumangaLocalTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFile(named name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("cbz".utf8).write(to: url)
        return url
    }

    @Test("Chapter titles drop the file extension")
    func chapterTitle() {
        #expect(LocalLibraryStore.chapterTitle(from: "Chapter 01.cbz") == "Chapter 01")
        #expect(LocalLibraryStore.chapterTitle(from: "oneshot.CBZ") == "oneshot")
        #expect(LocalLibraryStore.chapterTitle(from: "no extension") == "no extension")
    }

    @Test("Files sort naturally, so chapter 2 comes before chapter 10")
    func naturalOrder() {
        let names = ["Ch 10.cbz", "Ch 2.cbz", "Ch 1.cbz"]
        let urls = names.map { URL(fileURLWithPath: "/tmp/\($0)") }
        #expect(LocalLibraryStore.naturalSorted(urls).map(\.lastPathComponent) == [
            "Ch 1.cbz", "Ch 2.cbz", "Ch 10.cbz",
        ])
    }

    @Test("Importing several CBZ files makes one manga with numbered chapters")
    func createMangaGroupsFilesAsChapters() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sources = root.appendingPathComponent("source", isDirectory: true)
        // Deliberately out of order, to prove the import sorts them.
        let files = [
            try makeFile(named: "Ch 10.cbz", in: sources),
            try makeFile(named: "Ch 2.cbz", in: sources),
            try makeFile(named: "Ch 1.cbz", in: sources),
        ]

        let store = LocalLibraryStore(root: root.appendingPathComponent("library", isDirectory: true))
        let created = try store.createManga(
            title: "Uzumaki",
            description: "A spiral",
            author: "Junji Ito",
            artist: nil,
            genres: ["Horror"],
            status: .completed,
            cover: nil,
            files: files
        )

        // One manga, three chapters, in name order.
        let chapters = store.chapters(created.manga.mangaId)
        #expect(created.manga.sourceId == LocalLibrarySource.sourceId)
        #expect(chapters.map(\.title) == ["Ch 1", "Ch 2", "Ch 10"])
        #expect(chapters.map(\.number) == [1, 2, 3])
        #expect(chapters.map(\.order) == [0, 1, 2])

        // The CBZ files were actually copied in.
        let copied = try FileManager.default.contentsOfDirectory(
            at: store.chaptersDirectory(created.manga.mangaId),
            includingPropertiesForKeys: nil
        )
        #expect(copied.count == 3)

        // Metadata round-trips, and the manga rebuilds with it.
        let reloaded = store.manga(id: created.manga.mangaId)
        #expect(reloaded?.title == "Uzumaki")
        #expect(reloaded?.description == "A spiral")
        #expect(reloaded?.author == "Junji Ito")
        #expect(reloaded?.status == .completed)
    }

    @Test("Rewriting the chapter list rewrites the reading order")
    func chapterOrderIsPersisted() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LocalLibraryStore(root: root)
        let mangaId = UUID().uuidString
        try store.saveChapters(
            [
                LocalChapterEntry(id: "a", fileName: "a.cbz", title: "A", number: 1, order: 0),
                LocalChapterEntry(id: "b", fileName: "b.cbz", title: "B", number: 2, order: 1),
            ],
            mangaId: mangaId
        )

        // Swap them, as a drag-reorder would.
        var chapters = store.chapters(mangaId)
        chapters.swapAt(0, 1)
        try store.saveChapters(chapters, mangaId: mangaId)

        let reloaded = store.chapters(mangaId)
        #expect(reloaded.map(\.id) == ["b", "a"])
        #expect(reloaded.map(\.order) == [0, 1])
        #expect(reloaded.map(\.number) == [1, 2])
    }

    @Test("Dropping a folder imports one manga whose chapters are the files inside it")
    func importDroppedFolder() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("My Manga", isDirectory: true)
        _ = try makeFile(named: "Ch 2.cbz", in: folder)
        _ = try makeFile(named: "Ch 10.cbz", in: folder)
        _ = try makeFile(named: "Ch 1.pdf", in: folder)
        _ = try makeFile(named: "notes.txt", in: folder)

        let store = LocalLibraryStore(
            root: root.appendingPathComponent("library", isDirectory: true)
        )
        let mangas = try store.importDropped([folder])

        #expect(mangas.count == 1)
        #expect(mangas.first?.title == "My Manga")
        // Only the CBZ/PDF files become chapters, in natural name order.
        #expect(store.chapters(mangas[0].mangaId).map(\.title) == ["Ch 1", "Ch 2", "Ch 10"])
    }

    @Test("Deleting an import removes its files")
    func deleteMangaRemovesFiles() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source", isDirectory: true)
        let file = try makeFile(named: "Ch 1.cbz", in: source)

        let store = LocalLibraryStore(
            root: root.appendingPathComponent("library", isDirectory: true)
        )
        let created = try store.createManga(
            title: "Test",
            description: nil,
            author: nil,
            artist: nil,
            genres: [],
            status: .unknown,
            cover: nil,
            files: [file]
        )

        let directory = store.mangaDirectory(created.manga.mangaId)
        #expect(FileManager.default.fileExists(atPath: directory.path))

        store.deleteManga(id: created.manga.mangaId)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - PDF chapters

    /// A white page with a black square in its top-left corner. PDF space is y-up,
    /// so the square sits at the *high* end of y.
    private func makePDF(at url: URL, pages: Int) throws {
        let pageSize = CGSize(width: 200, height: 300)
        var box = CGRect(origin: .zero, size: pageSize)

        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else {
            throw LocalPDF.PDFError(message: "Could not build a test PDF.")
        }

        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(box)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: pageSize.height - 60, width: 60, height: 60))
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// The pixel at a fraction across and down the image, sampled from the top-left.
    private func sample(_ image: CGImage, xFraction: CGFloat, yFraction: CGFloat) -> (Int, Int, Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (0, 0, 0) }

        context.draw(
            image,
            in: CGRect(
                x: -(width * xFraction),
                y: (height * yFraction) - height,
                width: width,
                height: height
            )
        )
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    /// A page painted almost entirely black, leaving only a thin white border.
    private func makeFilledPDF(at url: URL) throws {
        let pageSize = CGSize(width: 200, height: 300)
        var box = CGRect(origin: .zero, size: pageSize)

        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else {
            throw LocalPDF.PDFError(message: "Could not build a test PDF.")
        }

        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(box)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 8, y: 8, width: pageSize.width - 16, height: pageSize.height - 16))
        context.endPDFPage()
        context.closePDF()
    }

    /// Fraction of an image that is dark.
    private func darkFraction(_ image: CGImage) -> Double {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)

        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var dark = 0
        var total = 0
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                let i = (y * width + x) * 4
                let value = (Int(data[i]) + Int(data[i + 1]) + Int(data[i + 2])) / 3
                if value < 128 { dark += 1 }
                total += 1
            }
        }
        return total > 0 ? Double(dark) / Double(total) : 0
    }

    @Test("A PDF page is rendered at the full size of the image, not shrunk into the middle")
    func pdfRendersAtFullScale() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdf = root.appendingPathComponent("filled.pdf")
        try makeFilledPDF(at: pdf)

        let directory = root.appendingPathComponent("pages", isDirectory: true)
        _ = try LocalPDF.render(pdf: pdf, to: directory, maxPixelSize: 400)

        let source = try #require(
            CGImageSourceCreateWithURL(directory.appendingPathComponent("0000.jpg") as CFURL, nil)
        )
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        // The page is almost entirely black. If the page were drawn at 1:1 in the
        // middle of a larger canvas — the bug this guards — the image would be mostly
        // white and this would be around 0.2.
        #expect(darkFraction(image) > 0.8)
    }

    @Test("A PDF chapter renders one upright image per page")
    func pdfRendersPages() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdf = root.appendingPathComponent("Chapter 1.pdf")
        try makePDF(at: pdf, pages: 2)
        #expect(LocalPDF.pageCount(of: pdf) == 2)
        #expect(LocalPDF.isPDF(pdf))
        #expect(!LocalPDF.isPDF(root.appendingPathComponent("Chapter 1.cbz")))

        let directory = root.appendingPathComponent("pages", isDirectory: true)
        let written = try LocalPDF.render(pdf: pdf, to: directory, maxPixelSize: 300)
        #expect(written == 2)

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(files.map(\.lastPathComponent) == ["0000.jpg", "0001.jpg"])

        let source = try #require(CGImageSourceCreateWithURL(files[0] as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        // A flip would put the marker in the bottom-left instead of the top-left.
        let topLeft = sample(image, xFraction: 0.15, yFraction: 0.1)
        let bottomRight = sample(image, xFraction: 0.85, yFraction: 0.9)
        #expect(topLeft.0 < 80 && topLeft.1 < 80 && topLeft.2 < 80)
        #expect(bottomRight.0 > 200 && bottomRight.1 > 200 && bottomRight.2 > 200)
    }

    @Test("Pages are listed in natural order and archive noise is ignored")
    func pageOrdering() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LocalLibraryStore(root: root)
        let pages = root.appendingPathComponent("pages", isDirectory: true)
        _ = try makeFile(named: "page10.png", in: pages)
        _ = try makeFile(named: "page2.png", in: pages)
        _ = try makeFile(named: "page1.png", in: pages)
        _ = try makeFile(named: "notes.txt", in: pages)
        _ = try makeFile(named: "cover.jpg", in: pages.appendingPathComponent("__MACOSX"))

        #expect(store.imageFiles(in: pages).map(\.lastPathComponent) == [
            "page1.png", "page2.png", "page10.png",
        ])
    }
}
