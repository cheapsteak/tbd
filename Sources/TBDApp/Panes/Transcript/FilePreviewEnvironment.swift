import Foundation
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

/// Best-effort extraction of `file_path` from a possibly-truncated tool input
/// JSON string. Returns nil if the field is absent or appears escaped.
/// Used so the Preview File button can render before full JSON is fetched.
enum ToolInputFilePath {
    private static let regex = try! NSRegularExpression(
        pattern: #""file_path"\s*:\s*"((?:[^"\\]|\\.)*)""#
    )
    static func extract(from json: String) -> String? {
        let range = NSRange(json.startIndex..., in: json)
        guard let m = regex.firstMatch(in: json, range: range), m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: json) else { return nil }
        let raw = String(json[r])
        // Only handle the unescaped-path case. If we see a backslash, give up
        // and let full-input fetch fix it later — paths with escapes are rare.
        if raw.contains("\\") { return nil }
        return raw
    }
}
