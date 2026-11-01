import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders a PDF to one image per page.
///
/// A PDF chapter is treated like a CBZ: its pages are rasterised once, on first
/// open, into the same `pages/<chapterId>/` folder. Nothing downstream — the reader,
/// the image pipeline, progress — needs to know PDFs are involved at all.
nonisolated enum LocalPDF {
    struct PDFError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    static func pageCount(of pdf: URL) -> Int {
        (CGPDFDocument(pdf as CFURL)?.numberOfPages) ?? 0
    }

    /// Writes `0000.jpg`, `0001.jpg`, … into `directory`, in page order.
    @discardableResult
    static func render(pdf: URL, to directory: URL, maxPixelSize: CGFloat = 2200) throws -> Int {
        guard let document = CGPDFDocument(pdf as CFURL) else {
            throw PDFError(message: "“\(pdf.lastPathComponent)” could not be opened as a PDF.")
        }
        guard document.numberOfPages > 0 else {
            throw PDFError(message: "“\(pdf.lastPathComponent)” has no pages.")
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written = 0
        for index in 1...document.numberOfPages {
            guard let page = document.page(at: index),
                  let image = render(page: page, maxPixelSize: maxPixelSize)
            else { continue }

            let url = directory.appendingPathComponent(String(format: "%04d.jpg", index - 1))
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else { continue }

            CGImageDestinationAddImage(destination, image, [
                kCGImageDestinationLossyCompressionQuality: 0.88,
            ] as CFDictionary)

            if CGImageDestinationFinalize(destination) {
                written += 1
            }
        }

        guard written > 0 else {
            throw PDFError(message: "No pages could be rendered from “\(pdf.lastPathComponent)”.")
        }
        return written
    }

    private static func render(page: CGPDFPage, maxPixelSize: CGFloat) -> CGImage? {
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }

        let rotation = page.rotationAngle
        let quarterTurned = rotation % 180 == 90
        let visible = quarterTurned
            ? CGSize(width: box.height, height: box.width)
            : CGSize(width: box.width, height: box.height)

        // Small pages are given a little headroom, large ones are scaled down.
        let scale = min(3, maxPixelSize / max(visible.width, visible.height))
        let width = max(1, Int((visible.width * scale).rounded()))
        let height = max(1, Int((visible.height * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        // A PDF's own background is transparent; manga pages are white.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Scale the page up to the bitmap first, then let `getDrawingTransform` place
        // it at 1:1 and apply its own rotation.
        //
        // It must be handed a rectangle the size of the *page*, not the bitmap: given
        // a larger rectangle it does not scale up, it centres the page at 1:1. That
        // drew every page at roughly half size in the middle of a mostly blank canvas,
        // so the artwork looked small with huge white margins baked into the image.
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.concatenate(
            page.getDrawingTransform(
                .mediaBox,
                rect: CGRect(origin: .zero, size: visible),
                rotate: rotation,
                preserveAspectRatio: true
            )
        )
        context.drawPDFPage(page)
        context.restoreGState()

        return context.makeImage()
    }
}
