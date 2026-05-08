import SwiftUI

/// Environment closure that opens a file path in a new code-viewer split.
private struct OpenFilePreviewKey: EnvironmentKey {
    static let defaultValue: (@MainActor (String) -> Void)? = nil
}

extension EnvironmentValues {
    var openFilePreview: (@MainActor (String) -> Void)? {
        get { self[OpenFilePreviewKey.self] }
        set { self[OpenFilePreviewKey.self] = newValue }
    }
}
