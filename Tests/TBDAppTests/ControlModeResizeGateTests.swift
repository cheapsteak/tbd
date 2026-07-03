import Testing
@testable import TBDApp

/// Pins the M3.2 resize gate. The Coordinator's `scheduleControlModeResize`
/// carries no untested conditional — the whole attach/size gate lives here,
/// one assertion per branch (CLAUDE.md gated-branch rule).
@Suite("ControlModeResizeGate.shouldSend")
struct ControlModeResizeGateTests {
    @Test("not attached → never send, regardless of size")
    func notAttached() {
        #expect(!ControlModeResizeGate.shouldSend(controlModeAttached: false, cols: 100, rows: 30))
        #expect(!ControlModeResizeGate.shouldSend(controlModeAttached: false, cols: 0, rows: 0))
    }

    @Test("attached + degenerate size → do not send (mid-layout artifact)")
    func attachedButDegenerate() {
        #expect(!ControlModeResizeGate.shouldSend(controlModeAttached: true, cols: 1, rows: 30))
        #expect(!ControlModeResizeGate.shouldSend(controlModeAttached: true, cols: 100, rows: 1))
        #expect(!ControlModeResizeGate.shouldSend(controlModeAttached: true, cols: 0, rows: 0))
    }

    @Test("attached + valid size → send")
    func attachedValid() {
        #expect(ControlModeResizeGate.shouldSend(controlModeAttached: true, cols: 2, rows: 2))
        #expect(ControlModeResizeGate.shouldSend(controlModeAttached: true, cols: 100, rows: 30))
    }
}
