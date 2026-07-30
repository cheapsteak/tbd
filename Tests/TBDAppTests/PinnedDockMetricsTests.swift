import CoreGraphics
import Testing
@testable import TBDApp

@Suite("Pinned dock sizing")
struct PinnedDockMetricsTests {
    /// A tall sidebar, so the fraction clamp never binds in these cases.
    private let tall: CGFloat = 1000

    @Test("no rows means no dock")
    func zeroRows() {
        #expect(PinnedDockMetrics.height(rowCount: 0, availableHeight: tall) == 0)
    }

    @Test("below the cap, height is one row per pin")
    func belowCap() {
        #expect(PinnedDockMetrics.height(rowCount: 3, availableHeight: tall)
                == 3 * PinnedDockMetrics.rowHeight)
    }

    @Test("at the cap, height is exactly maxRows")
    func atCap() {
        #expect(PinnedDockMetrics.height(rowCount: PinnedDockMetrics.maxRows, availableHeight: tall)
                == CGFloat(PinnedDockMetrics.maxRows) * PinnedDockMetrics.rowHeight)
    }

    @Test("above the cap, height clamps to maxRows")
    func aboveCap() {
        #expect(PinnedDockMetrics.height(rowCount: 40, availableHeight: tall)
                == CGFloat(PinnedDockMetrics.maxRows) * PinnedDockMetrics.rowHeight)
    }

    @Test("a short sidebar clamps to 40% of available height")
    func shortSidebar() {
        // 5 rows would want 130pt, but 40% of 200 is 80.
        #expect(PinnedDockMetrics.height(rowCount: 5, availableHeight: 200) == 80)
    }

    @Test("a negative or zero sidebar height never yields a negative dock")
    func degenerateSidebar() {
        #expect(PinnedDockMetrics.height(rowCount: 3, availableHeight: 0) == 0)
        #expect(PinnedDockMetrics.height(rowCount: 3, availableHeight: -50) == 0)
    }
}
