import Testing
@testable import TBDApp

/// The pure routing decision for one SwiftTerm outgoing byte chunk. Each gated
/// branch (CLAUDE.md: a test per branch) is asserted directly so the Coordinator
/// body — UI code — carries no untested conditional.
@Suite("OutgoingInputRoute.decide")
struct OutgoingInputRouteTests {
    @Test("no control-mode attach → local PTY regardless of size")
    func localPTYWhenNotAttached() {
        #expect(OutgoingInputRoute.decide(controlModeAttached: false, byteCount: 1) == .localPTY)
        #expect(OutgoingInputRoute.decide(controlModeAttached: false, byteCount: 100_000) == .localPTY)
        #expect(OutgoingInputRoute.decide(controlModeAttached: false, byteCount: 0) == .localPTY)
    }

    @Test("control mode + at-or-below threshold → sidecar input")
    func sidecarWhenSmall() {
        #expect(OutgoingInputRoute.decide(controlModeAttached: true, byteCount: 1) == .sidecarInput)
        #expect(OutgoingInputRoute.decide(controlModeAttached: true, byteCount: 1000) == .sidecarInput)
    }

    @Test("control mode at exactly the threshold → sidecar input (boundary)")
    func sidecarAtBoundary() {
        #expect(OutgoingInputRoute.pasteThresholdBytes == 4096)
        #expect(OutgoingInputRoute.decide(
            controlModeAttached: true,
            byteCount: OutgoingInputRoute.pasteThresholdBytes) == .sidecarInput)
    }

    @Test("control mode above the threshold → paste RPC")
    func pasteWhenLarge() {
        #expect(OutgoingInputRoute.decide(
            controlModeAttached: true,
            byteCount: OutgoingInputRoute.pasteThresholdBytes + 1) == .pasteRPC)
        #expect(OutgoingInputRoute.decide(controlModeAttached: true, byteCount: 1_000_000) == .pasteRPC)
    }
}
