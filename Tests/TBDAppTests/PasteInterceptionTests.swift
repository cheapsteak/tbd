import Testing
import Foundation
import TBDShared
@testable import TBDApp

/// Pins the paste ruling v2's view-level decision. The Coordinator's
/// `onControlModePaste` closure carries no untested size/attach conditional —
/// the whole gate lives here, one test per branch.
///
/// The ruling: while a control-mode attach is live, NO paste bytes ever take
/// SwiftTerm's keystroke path — every paste, any size, is intercepted before
/// SwiftTerm brackets it and shipped as a `.paste` sidecar frame, making tmux
/// (`paste-buffer -p`) the sole bracketed-paste authority. Oversize pastes
/// (> the sidecar paste cap) are REFUSED (logged + dropped), not split and not
/// keystroke-encoded. Detached panes keep SwiftTerm's local bracketed paste.
@Suite("PasteInterception.decide")
struct PasteInterceptionTests {
    @Test("not attached → passthrough (SwiftTerm brackets locally), regardless of size")
    func detachedPassthrough() {
        for byteCount in [0, 1, 4096, 4097, SidecarFrameCodec.maxPasteBytes,
                          SidecarFrameCodec.maxPasteBytes + 1] {
            #expect(PasteInterception.decide(
                controlModeAttached: false, byteCount: byteCount) == .passthrough)
        }
    }

    @Test("attached + within the cap → intercept as .paste frame (no small-paste keystroke rider)")
    func attachedInterceptsAllSizes() {
        // 4096/4097 straddle the RETIRED M2 threshold: both must intercept now.
        for byteCount in [1, 2, 4095, 4096, 4097, SidecarFrameCodec.maxPasteBytes] {
            #expect(PasteInterception.decide(
                controlModeAttached: true, byteCount: byteCount) == .interceptAsPaste)
        }
    }

    @Test("attached + empty → still intercepted, never the keystroke path (caller sends no frame)")
    func attachedEmptyConsumedWithoutFrame() {
        // Zero bytes must not fall through to SwiftTerm either — its stale
        // 2004-bracketing could still emit a bare ESC[200~/201~ pair. The
        // wiring skips the sidecar frame for an empty payload.
        #expect(PasteInterception.decide(
            controlModeAttached: true, byteCount: 0) == .interceptAsPaste)
    }

    @Test("attached + over the cap → refuse (log + drop; keystroke path is not a valid fallback)")
    func attachedOversizeRefused() {
        #expect(PasteInterception.decide(
            controlModeAttached: true,
            byteCount: SidecarFrameCodec.maxPasteBytes + 1) == .refuseOversize)
        #expect(PasteInterception.decide(
            controlModeAttached: true, byteCount: 100_000_000) == .refuseOversize)
    }
}
