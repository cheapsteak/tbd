import CoreGraphics
import Foundation
import Testing
@testable import TBDApp

@Suite("Terminal wheel routing")
struct TerminalWheelRoutingTests {
    private func disposition(
        deltaY: CGFloat = 0,
        scrollingDeltaY: CGFloat = 0,
        overlayOpen: Bool = false,
        pointerInside: Bool = true,
        mouseReportingOn: Bool = true
    ) -> TerminalWheelRouting.Disposition {
        TerminalWheelRouting.disposition(
            deltaY: deltaY,
            scrollingDeltaY: scrollingDeltaY,
            overlayOpen: overlayOpen,
            pointerInside: pointerInside,
            mouseReportingOn: mouseReportingOn
        )
    }

    @Test("scrolling up forwards mouse button 4")
    func upForwardsButtonFour() {
        #expect(disposition(deltaY: 1) == .forward(button: 4, count: 1))
    }

    @Test("scrolling down forwards mouse button 5")
    func downForwardsButtonFive() {
        #expect(disposition(deltaY: -1) == .forward(button: 5, count: 1))
    }

    @Test("line count comes from the magnitude of deltaY, and is at least one")
    func countTracksDeltaMagnitude() {
        #expect(disposition(deltaY: 3.9) == .forward(button: 4, count: 3))
        #expect(disposition(deltaY: -7) == .forward(button: 5, count: 7))
        #expect(disposition(deltaY: 0.25) == .forward(button: 4, count: 1))
        #expect(disposition(deltaY: -0.25) == .forward(button: 5, count: 1))
    }

    @Test("a precise-scroll event with no line delta still forwards")
    func scrollingDeltaAloneForwards() {
        // SwiftTerm's own scrollWheel reads scrollingDeltaY, so an event with
        // deltaY == 0 would become cursor keys if we handed it back.
        #expect(disposition(deltaY: 0, scrollingDeltaY: 4) == .forward(button: 4, count: 1))
        #expect(disposition(deltaY: 0, scrollingDeltaY: -4) == .forward(button: 5, count: 1))
    }

    @Test("an event with no vertical motion passes through")
    func noMotionPassesThrough() {
        #expect(disposition(deltaY: 0, scrollingDeltaY: 0) == .passThrough)
    }

    @Test("an open overlay owns the event")
    func overlayPassesThrough() {
        #expect(disposition(deltaY: 3, overlayOpen: true) == .passThrough)
        #expect(disposition(deltaY: 0, scrollingDeltaY: 3, overlayOpen: true) == .passThrough)
    }

    @Test("a pointer outside the terminal passes through")
    func outsidePassesThrough() {
        #expect(disposition(deltaY: 3, pointerInside: false) == .passThrough)
    }

    @Test("with tmux mouse reporting off the event is swallowed, never passed through")
    func mouseReportingOffSwallows() {
        // The regression: a passed-through event reaches SwiftTerm, which
        // translates it into Up/Down cursor keys on the alternate screen, and
        // Claude Code's composer reads Up as prompt-history recall.
        let up = disposition(deltaY: 3, mouseReportingOn: false)
        #expect(up == .swallow)
        #expect(up != .passThrough)

        let down = disposition(deltaY: -3, mouseReportingOn: false)
        #expect(down == .swallow)
        #expect(down != .passThrough)
    }

    @Test("a wheel event over the terminal is never handed back to AppKit")
    func ourEventsAreNeverPassedThrough() {
        let deltas: [CGFloat] = [-8, -1, -0.4, 0, 0.4, 1, 8]
        for deltaY in deltas {
            for scrollingDeltaY in deltas {
                for mouseReportingOn in [true, false] {
                    let result = disposition(
                        deltaY: deltaY,
                        scrollingDeltaY: scrollingDeltaY,
                        overlayOpen: false,
                        pointerInside: true,
                        mouseReportingOn: mouseReportingOn
                    )
                    let hasMotion = deltaY != 0 || scrollingDeltaY != 0
                    if hasMotion {
                        #expect(
                            result != .passThrough,
                            "deltaY \(deltaY), scrollingDeltaY \(scrollingDeltaY), reporting \(mouseReportingOn)"
                        )
                    } else {
                        #expect(result == .passThrough)
                    }
                }
            }
        }
    }

    // MARK: - Grid clamping

    private static let cell = (width: CGFloat(10), height: CGFloat(20))

    @Test("an interior point matches the unclamped grid math")
    func interiorPointMatchesUnclampedMath() {
        // 80 cols x 5 rows, bounds 800 x 100.
        let grid = TerminalWheelRouting.clampedGrid(
            localPoint: CGPoint(x: 35, y: 55),
            boundsHeight: 100,
            cell: Self.cell,
            cols: 80,
            rows: 5
        )
        #expect(grid.col == 3)
        #expect(grid.row == 2)
    }

    @Test("the slack strip below the last row clamps to the last row")
    func bottomSlackClampsToLastRow() {
        // Bounds are 110 tall but only 5 rows of 20 fit, so y < 10 is slack.
        let grid = TerminalWheelRouting.clampedGrid(
            localPoint: CGPoint(x: 5, y: 2),
            boundsHeight: 110,
            cell: Self.cell,
            cols: 80,
            rows: 5
        )
        #expect(grid.row == 4)
        #expect(grid.col == 0)
    }

    @Test("the sliver right of the last column clamps to the last column")
    func rightSliverClampsToLastColumn() {
        let grid = TerminalWheelRouting.clampedGrid(
            localPoint: CGPoint(x: 806, y: 90),
            boundsHeight: 100,
            cell: Self.cell,
            cols: 80,
            rows: 5
        )
        #expect(grid.col == 79)
        #expect(grid.row == 0)
    }

    @Test("a point above or left of the grid clamps to the first cell")
    func negativePointClampsToOrigin() {
        let grid = TerminalWheelRouting.clampedGrid(
            localPoint: CGPoint(x: -30, y: 140),
            boundsHeight: 100,
            cell: Self.cell,
            cols: 80,
            rows: 5
        )
        #expect(grid.col == 0)
        #expect(grid.row == 0)
    }

    @Test("a degenerate grid resolves to the origin instead of trapping")
    func degenerateGridIsSafe() {
        let noRows = TerminalWheelRouting.clampedGrid(
            localPoint: CGPoint(x: 40, y: 40),
            boundsHeight: 100,
            cell: Self.cell,
            cols: 80,
            rows: 0
        )
        #expect(noRows.col == 0)
        #expect(noRows.row == 0)

        let noCell = TerminalWheelRouting.clampedGrid(
            localPoint: CGPoint(x: 40, y: 40),
            boundsHeight: 100,
            cell: (width: 0, height: 0),
            cols: 80,
            rows: 5
        )
        #expect(noCell.col == 0)
        #expect(noCell.row == 0)
    }
}
