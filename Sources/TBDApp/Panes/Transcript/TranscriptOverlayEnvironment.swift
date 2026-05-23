import SwiftUI

/// Closure injected by `LiveTranscriptPaneView` (which knows its bound
/// `terminalID`) so any transcript row card can request the overlay
/// without knowing which terminal it belongs to. The closure takes only
/// the item ID; the terminalID is captured at injection time.
struct OpenTranscriptOverlayKey: EnvironmentKey {
    static let defaultValue: (@MainActor (String) -> Void)? = nil
}

extension EnvironmentValues {
    var openTranscriptOverlay: (@MainActor (String) -> Void)? {
        get { self[OpenTranscriptOverlayKey.self] }
        set { self[OpenTranscriptOverlayKey.self] = newValue }
    }
}
