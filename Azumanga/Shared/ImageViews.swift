import CoreGraphics
import SwiftUI

/// The page tint used by the reader's warmth control.
enum ReaderWarmth {
    /// White is multiplied by this color at maximum warmth.
    static let maximumColor = Color(
        .sRGB,
        red: 241.0 / 255.0,
        green: 225.0 / 255.0,
        blue: 201.0 / 255.0
    )

    /// Interpolates from an identity multiplier to `maximumColor`.
    static func multiplier(for amount: Double) -> Color {
        let value = min(max(amount, 0), 1)
        return Color(
            .sRGB,
            red: 1 + (241.0 / 255.0 - 1) * value,
            green: 1 + (225.0 / 255.0 - 1) * value,
            blue: 1 + (201.0 / 255.0 - 1) * value
        )
    }

    static func components(for amount: Double) -> (red: Double, green: Double, blue: Double) {
        let value = min(max(amount, 0), 1)
        return (
            1 + (241.0 / 255.0 - 1) * value,
            1 + (225.0 / 255.0 - 1) * value,
            1 + (201.0 / 255.0 - 1) * value
        )
    }
}

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
    /// Page tint from 0 (unchanged) to 1 (`#f1e1c9` white point).
    var warmth: Double = 0

    @Environment(\.imagePipeline) private var pipeline
    @State private var image: CGImage?
    @State private var failureMessage: String?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .colorMultiply(ReaderWarmth.multiplier(for: warmth))
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
