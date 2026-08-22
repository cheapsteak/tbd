import SwiftUI

/// Environment closure that opens a link clicked inside transcript text.
///
/// Deliberately separate from `\.openFilePreview`, which the Read/Write/Edit
/// tool cards use: those open a floating overlay, while a link click swaps the
/// panel's viewer slot. Same destination file, different gesture, different
/// surface.
private struct OpenTranscriptLinkKey: EnvironmentKey {
    static let defaultValue: (@MainActor (TranscriptLinkTarget) -> Void)? = nil
}

extension EnvironmentValues {
    var openTranscriptLink: (@MainActor (TranscriptLinkTarget) -> Void)? {
        get { self[OpenTranscriptLinkKey.self] }
        set { self[OpenTranscriptLinkKey.self] = newValue }
    }
}
