import TBDShared
import Testing
@testable import TBDApp

/// Pins the M3.2 resize gate. The Coordinator's `scheduleDaemonResize`
/// carries no untested conditional — the whole attach/size gate lives here,
/// one assertion per branch (CLAUDE.md gated-branch rule).
///
/// The size floor is the SHARED `TerminalGeometryLimits` floor (R6-M5): the app
/// must never send a size the daemon would floor-clamp, or the pane
/// permanently desyncs (the daemon clamps, the echo fence suppresses the
/// resulting layout change, and nothing reports the clamp back).
@Suite("TerminalResizeGate.shouldSend")
struct TerminalResizeGateTests {
    @Test("not attached → never send, regardless of size")
    func notAttached() {
        #expect(!TerminalResizeGate.shouldSend(targetAttached: false, cols: 100, rows: 30))
        #expect(!TerminalResizeGate.shouldSend(targetAttached: false, cols: 0, rows: 0))
    }

    @Test("attached + below the shared floor → do not send (the daemon would clamp it)")
    func attachedBelowSharedFloor() {
        #expect(!TerminalResizeGate.shouldSend(
            targetAttached: true, cols: TerminalGeometryLimits.minCols - 1, rows: 100))
        #expect(!TerminalResizeGate.shouldSend(
            targetAttached: true, cols: 100, rows: TerminalGeometryLimits.minRows - 1))
        // Degenerate mid-layout artifacts stay refused too.
        #expect(!TerminalResizeGate.shouldSend(targetAttached: true, cols: 1, rows: 30))
        #expect(!TerminalResizeGate.shouldSend(targetAttached: true, cols: 0, rows: 0))
    }

    @Test("attached + at or above the shared floor → send")
    func attachedAtOrAboveFloor() {
        #expect(TerminalResizeGate.shouldSend(
            targetAttached: true,
            cols: TerminalGeometryLimits.minCols, rows: TerminalGeometryLimits.minRows))
        #expect(TerminalResizeGate.shouldSend(targetAttached: true, cols: 100, rows: 30))
    }

    @Test("the app gate's floor IS the daemon clamp floor — one shared constant")
    func floorMatchesDaemonClamp() {
        // Pin the actual values so a drive-by edit to either side of the
        // shared constant is a conscious, test-visible decision.
        #expect(TerminalGeometryLimits.minCols == 20)
        #expect(TerminalGeometryLimits.minRows == 5)
    }
}
