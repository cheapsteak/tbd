import Foundation
import TBDShared

/// Pure decision for where a pasteboard paste goes when it hits the SwiftTerm
/// view (the paste ruling v2, superseding the M2 rider): while a control-mode
/// attach is live, EVERY paste — any size — is intercepted BEFORE SwiftTerm
/// brackets it and shipped as a `.paste` sidecar frame (daemon side:
/// `load-buffer` + `paste-buffer -d -p`). tmux is the SOLE bracketed-paste
/// authority.
///
/// That authority is CONTINGENT, and the precondition is worth naming here
/// because nothing in this file expresses it: `paste-buffer -p` wraps in
/// ESC[200~/ESC[201~ only *because* the application in the pane has enabled
/// bracketed-paste mode (DECSET 2004). Against a pane whose app has not, the
/// same `-p` delivers the bytes verbatim — measured on tmux 3.6a, 22 wrapped
/// bytes vs 10 bare for the same payload. So if an agent TUI ever stops
/// setting 2004, nothing on this path wraps and "SOLE authority" becomes
/// "no authority". Asserted nightly by probe P3 in
/// `scripts/nightly-tmux-probes.sh` (two arms: 2004 on -> wrapped, off ->
/// verbatim), so the comment and the check move together.
///
/// Why no keystroke-path rider survives: stock tmux (our 3.2 floor) exposes no
/// bracketed-paste format variable, so §3's attach replay cannot restore
/// SwiftTerm's DECSET-2004 tracking after a tab-switch re-attach — SwiftTerm's
/// own bracketing decision on the keystroke path can be stale-wrong. That
/// retires both the old ≤4 KiB fallthrough AND the oversize keystroke fallback:
///
/// - `.interceptAsPaste`: ship the bytes as one `.paste` frame. Callers send
///   NO frame for an empty payload (nothing to paste; zero-byte frames are
///   never sent) but still consume the paste — even an empty paste must not
///   reach SwiftTerm, whose stale bracketing could emit a bare marker pair.
/// - `.refuseOversize`: over `SidecarFrameCodec.maxPasteBytes` — the caller
///   logs a user-visible error and DROPS the paste. Never split across frames
///   (each `.paste` frame is its own `paste-buffer` call, which tmux would
///   bracket as a separate paste), never the keystroke path.
/// - `.passthrough`: no attach — SwiftTerm's normal local bracketed paste,
///   exactly as before control mode existed.
enum PasteInterception {
    enum Decision: Equatable {
        case interceptAsPaste
        case refuseOversize
        case passthrough
    }

    static func decide(controlModeAttached: Bool, byteCount: Int) -> Decision {
        guard controlModeAttached else { return .passthrough }
        return byteCount > SidecarFrameCodec.maxPasteBytes ? .refuseOversize : .interceptAsPaste
    }

    /// User-visible status line for a `.refuseOversize` paste, fed into the
    /// terminal view by the caller — a log entry alone is invisible to the
    /// user, who otherwise sees the paste silently vanish. Framed
    /// `"\r\n[...]\r\n"` to match the panel's other in-pane status feeds
    /// (view-detached / session-expired messages in `TerminalPanelView`).
    static func refusalMessage(byteCount: Int, cap: Int = SidecarFrameCodec.maxPasteBytes) -> String {
        "\r\n[Paste too large: \(humanBytes(byteCount)) exceeds the \(humanBytes(cap)) "
            + "control-mode limit — the paste was not sent. Split it into smaller pastes.]\r\n"
    }

    /// Binary-unit human formatting (one decimal), floored at whole bytes so
    /// small counts never render as "0.0 KB".
    private static func humanBytes(_ count: Int) -> String {
        let mb = Double(count) / (1024 * 1024)
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        let kb = Double(count) / 1024
        if kb >= 1 { return String(format: "%.1f KB", kb) }
        return "\(count) bytes"
    }
}
