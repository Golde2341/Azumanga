import CoreGraphics
import SwiftUI

/// Loads and displays a cover image from an arbitrary URL using the shared
/// image pipeline. Never blocks layout: shows a placeholder until decoded.
struct CoverImage: View {
    let url: URL?
    var maxPixelSize: Int = 512

    @Environment(\.imagePipeline) private var pipeline
    @State private var image: CGImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .clipped()
        .task(id: url) {
            await load()
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: didFail || url == nil ? "photo" : "photo.on.rectangle.angled")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
    }

    private func load() async {
        image = nil
        didFail = false
        guard let url else {
            didFail = true
            return
        }
        if let cached = await pipeline.cachedImage(for: url, maxPixelSize: maxPixelSize) {
            image = cached
            return
        }
        do {
            let loaded = try await pipeline.image(for: url, maxPixelSize: maxPixelSize)
            try Task.checkCancellation()
            image = loaded
        } catch is CancellationError {
            // View went away; leave the placeholder in place.
        } catch {
            didFail = true
        }
    }
}

/// Displays a single manga page, decoding to the requested render size.
struct AsyncPageImage: View {
    let page: Page
    var maxPixelSize: Int
    var contentMode: ContentMode = .fit

    @Environment(\.imagePipeline) private var pipeline
    @State private var image: CGImage?
    @State private var failureMessage: String?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if let failureMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                    Text(failureMessage)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 320)
            }
        }
        .task(id: page.url) {
            await load()
        }
    }

    private func load() async {
        image = nil
        failureMessage = nil
        if let cached = await pipeline.cachedImage(for: page.url, maxPixelSize: maxPixelSize) {
            image = cached
            return
        }
        do {
            let loaded = try await pipeline.image(for: page, maxPixelSize: maxPixelSize)
            try Task.checkCancellation()
            image = loaded
        } catch is CancellationError {
            // Cancelled because the page scrolled away.
        } catch {
            failureMessage = (error as? LocalizedError)?.errorDescription ?? "Could not load page"
        }
    }
}
