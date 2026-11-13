import Foundation
import TBDShared

/// Pure decision for whether the Coordinator should send a `pane.resize` for
/// a given proposed geometry (M3.2). Extracted so the gated branch in
/// `sizeChanged` / `scheduleDaemonResize` carries no untested conditional —
/// mirrors `OutgoingInputRoute` / `PasteInterception`.
///
/// A resize is sent only when this panel has a resize target AND the size is
/// at or above the `TerminalGeometryLimits` floor. What the floor does
/// depends on the transport:
///
/// - On both transports it keeps a degenerate grid from reaching the daemon.
///   SwiftTerm emits transient tiny sizes (0/1 cols/rows) mid-layout, and
///   none of them should become a `pane.resize`. A holder attach applies the
///   same check to the grid it asks the daemon to write its snapshot at.
/// - On the control-mode transport it also matches the daemon's clamp
///   (R6-M5). `ControlModeResizeCoordinator` clamps `resize-window` to the
///   same floor, and a size below it would be clamped with no report back
///   (the echo fence suppresses our own `%layout-change`), permanently
///   desyncing SwiftTerm from tmux. Accepted residual: a panel physically
///   below the floor keeps tmux at its last >= floor size, and self-heals on
///   the next >= floor resize.
/// - On the holder transport the daemon does not clamp:
///   `HolderRegistry.applyViewerResize` applies whatever size arrives. Nor
///   does this gate decide the child's tty size there — the panel sets that
///   on its own descriptor (`setHolderWindowSize`), skipping only a zero
///   size.
enum TerminalResizeGate {
    static func shouldSend(targetAttached: Bool, cols: Int, rows: Int) -> Bool {
        guard targetAttached else { return false }
        return cols >= TerminalGeometryLimits.minCols && rows >= TerminalGeometryLimits.minRows
    }
}
