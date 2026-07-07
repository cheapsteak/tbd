import Testing
@testable import TBDApp

/// The pure routing decision for one SwiftTerm outgoing byte chunk. Each gated
/// branch (CLAUDE.md: a test per branch) is asserted directly so the Coordinator
/// body — UI code — carries no untested conditional.
///
/// Size no longer factors in here: while attached, EVERY paste is intercepted
/// at the VIEW level (before SwiftTerm brackets it) and shipped as a `.paste`
/// sidecar frame, or refused when oversize — see `PasteInterceptionTests` for
/// that gate. Everything that reaches SwiftTerm's `send(...)` is a keystroke,
/// so this decision is purely attached → sidecar / not-attached → local PTY.
@Suite("OutgoingInputRoute.decide")
struct OutgoingInputRouteTests {
    @Test("no control-mode attach → local PTY regardless of size")
    func localPTYWhenNotAttached() {
        #expect(OutgoingInputRoute.decide(controlModeAttached: false, byteCount: 1) == .localPTY)
        #expect(OutgoingInputRoute.decide(controlModeAttached: false, byteCount: 100_000) == .localPTY)
        #expect(OutgoingInputRoute.decide(controlModeAttached: false, byteCount: 0) == .localPTY)
    }

    @Test("control-mode attach → sidecar input regardless of size")
    func sidecarWhenAttached() {
        #expect(OutgoingInputRoute.decide(controlModeAttached: true, byteCount: 1) == .sidecarInput)
        #expect(OutgoingInputRoute.decide(controlModeAttached: true, byteCount: 1000) == .sidecarInput)
        #expect(OutgoingInputRoute.decide(controlModeAttached: true, byteCount: 1_000_000) == .sidecarInput)
    }
}
