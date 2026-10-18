import SwiftUI

/// Process-wide default services for previews and views used outside the app
/// container. The running app overrides the image pipeline with its own instance.
nonisolated enum AppImages {
    static let shared = ImagePipeline(
        http: HTTPClient(),
        memory: MemoryImageCache(),
        disk: DiskImageCache(directory: DiskImageCache.defaultDirectory)
    )
}

nonisolated private struct ImagePipelineKey: EnvironmentKey {
    static let defaultValue = AppImages.shared
}

nonisolated extension EnvironmentValues {
    var imagePipeline: ImagePipeline {
        get { self[ImagePipelineKey.self] }
        set { self[ImagePipelineKey.self] = newValue }
    }
}
