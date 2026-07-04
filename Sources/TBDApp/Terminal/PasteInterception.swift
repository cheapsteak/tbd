import Foundation
import TBDShared

/// Pure decision for where a pasteboard paste goes when it hits the SwiftTerm
/// view (the paste ruling v2, superseding the M2 rider): while a control-mode
/// attach is live, EVERY paste — any size — is intercepted BEFORE SwiftTerm
/// brackets it and shipped as a `.paste` sidecar frame (daemon side:
/// `load-buffer` + `paste-buffer -d -p`). tmux is the SOLE bracketed-paste
/// authority.
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
}
