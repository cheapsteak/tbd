import Foundation
import TBDShared

/// Pure decision for whether the Coordinator should send a `pane.resize` for
/// a given proposed geometry. Extracted so the gated branch in
/// `scheduleDaemonResize` and the holder attach carries no untested
/// conditional.
///
/// The floor (`TerminalGeometryLimits`) keeps a degenerate grid from reaching
/// the daemon. SwiftTerm emits transient tiny sizes (0/1 cols/rows)
/// mid-layout, and none of them should become a `pane.resize`. A holder attach
/// applies the same check to the grid it asks the daemon to write its snapshot
/// at.
///
/// The floor is the panel's, not the daemon's:
/// `HolderRegistry.applyViewerResize` applies whatever size arrives. Nor does
/// this gate decide the child's tty size — the panel sets that on its own
/// descriptor (`setHolderWindowSize`), skipping only a zero size.
enum TerminalResizeGate {
    static func shouldSend(cols: Int, rows: Int) -> Bool {
        cols >= TerminalGeometryLimits.minCols && rows >= TerminalGeometryLimits.minRows
    }
}
