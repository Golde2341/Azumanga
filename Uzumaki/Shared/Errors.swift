import Foundation

/// Converts any thrown error into a message suitable for display.
nonisolated func userFacingMessage(for error: Error) -> String {
    if let localized = error as? LocalizedError, let description = localized.errorDescription {
        return description
    }
    return error.localizedDescription
}
