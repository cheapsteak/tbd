import Foundation
import TBDShared

/// Pure decision for whether a pasteboard paste should be intercepted at the
/// SwiftTerm view level and shipped as a `.paste` sidecar frame (the M2 paste
/// ruling), rather than flowing through SwiftTerm's normal keystroke path.
///
/// Interception is deliberately NARROW:
/// - **≤ 4 KiB pastes are NOT intercepted** (rider 1). SwiftTerm delivers a
///   bracketed paste as three ordered `send()` calls (ESC[200~ / content /
///   ESC[201~); riding the keystroke path keeps that sequence correct and
///   FIFO-ordered end-to-end. Only large pastes — where keystroke-encoding the
///   whole payload is wasteful — take the `.paste` frame.
/// - **Oversize pastes fall back too** (rider 2): a payload past the sidecar's
///   documented paste cap is NOT split across frames; it takes SwiftTerm's
///   normal path (correct, just slower).
enum PasteInterception {
    /// Pastes at or below this size ride the keystroke path unchanged.
    static let thresholdBytes = 4096

    /// True only when control mode is attached and the payload is in the
    /// intercept window `(thresholdBytes, maxPasteBytes]`.
    static func shouldIntercept(controlModeAttached: Bool, byteCount: Int) -> Bool {
        guard controlModeAttached else { return false }
        return byteCount > thresholdBytes && byteCount <= SidecarFrameCodec.maxPasteBytes
    }
}
