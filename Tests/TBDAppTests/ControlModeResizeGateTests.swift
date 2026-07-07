import TBDShared
import Testing
@testable import TBDApp

/// Pins the M3.2 resize gate. The Coordinator's `scheduleControlModeResize`
/// carries no untested conditional — the whole attach/size gate lives here,
/// one assertion per branch (CLAUDE.md gated-branch rule).
///
/// The size floor is the SHARED `ControlModeGeometry` floor (R6-M5): the app
/// must never send a size the daemon would floor-clamp, or the pane
/// permanently desyncs (the daemon clamps, the echo fence suppresses the
/// resulting layout change, and nothing reports the clamp back).
@Suite("ControlModeResizeGate.shouldSend")
struct ControlModeResizeGateTests {
    @Test("not attached → never send, regardless of size")
    func notAttached() {
        #expect(!ControlModeResizeGate.shouldSend(controlModeAttached: false, cols: 100, rows: 30))
        #expect(!ControlModeResizeGate.shouldSend(controlModeAttached: false, cols: 0, rows: 0))
    }

    @Test("attached + below the shared floor → do not send (the daemon would clamp it)")
    func attachedBelowSharedFloor() {
        #expect(!ControlModeResizeGate.shouldSend(
            controlModeAttached: true, cols: ControlModeGeometry.minCols - 1, rows: 100))
        #expect(!ControlModeResizeGate.shouldSend(
            controlModeAttached: true, cols: 100, rows: ControlModeGeometry.minRows - 1))
        // Degenerate mid-layout artifacts stay refused too.
        #expect(!ControlModeResizeGate.shouldSend(controlModeAttached: true, cols: 1, rows: 30))
        #expect(!ControlModeResizeGate.shouldSend(controlModeAttached: true, cols: 0, rows: 0))
    }

    @Test("attached + at or above the shared floor → send")
    func attachedAtOrAboveFloor() {
        #expect(ControlModeResizeGate.shouldSend(
            controlModeAttached: true,
            cols: ControlModeGeometry.minCols, rows: ControlModeGeometry.minRows))
        #expect(ControlModeResizeGate.shouldSend(controlModeAttached: true, cols: 100, rows: 30))
    }

    @Test("the app gate's floor IS the daemon clamp floor — one shared constant")
    func floorMatchesDaemonClamp() {
        // Pin the actual values so a drive-by edit to either side of the
        // shared constant is a conscious, test-visible decision.
        #expect(ControlModeGeometry.minCols == 20)
        #expect(ControlModeGeometry.minRows == 5)
    }
}
