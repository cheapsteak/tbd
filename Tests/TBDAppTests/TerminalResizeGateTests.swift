import TBDShared
import Testing
@testable import TBDApp

/// Pins the resize gate. The Coordinator's `scheduleDaemonResize` and the
/// holder attach carry no untested conditional — the size gate lives here, one
/// assertion per branch (CLAUDE.md gated-branch rule).
///
/// The floor is `TerminalGeometryLimits`: SwiftTerm emits transient tiny sizes
/// mid-layout, and none of them should reach the daemon as a `pane.resize`.
@Suite("TerminalResizeGate.shouldSend")
struct TerminalResizeGateTests {
    @Test("below the floor → do not send")
    func belowFloor() {
        #expect(!TerminalResizeGate.shouldSend(
            cols: TerminalGeometryLimits.minCols - 1, rows: 100))
        #expect(!TerminalResizeGate.shouldSend(
            cols: 100, rows: TerminalGeometryLimits.minRows - 1))
        // Degenerate mid-layout artifacts stay refused too.
        #expect(!TerminalResizeGate.shouldSend(cols: 1, rows: 30))
        #expect(!TerminalResizeGate.shouldSend(cols: 0, rows: 0))
    }

    @Test("at or above the floor → send")
    func atOrAboveFloor() {
        #expect(TerminalResizeGate.shouldSend(
            cols: TerminalGeometryLimits.minCols, rows: TerminalGeometryLimits.minRows))
        #expect(TerminalResizeGate.shouldSend(cols: 100, rows: 30))
    }

    @Test("the floor's values are pinned")
    func floorValuesArePinned() {
        // Pin the actual values so a drive-by edit to the shared constant is a
        // conscious, test-visible decision.
        #expect(TerminalGeometryLimits.minCols == 20)
        #expect(TerminalGeometryLimits.minRows == 5)
    }
}
