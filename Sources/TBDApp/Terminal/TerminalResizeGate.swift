import Foundation
import TBDShared

/// Pure decision for whether the Coordinator should send a `pane.resize` for
/// a given proposed geometry (M3.2), on either the control-mode or the
/// pty-holder transport. Extracted so the gated branch in `sizeChanged` /
/// `scheduleDaemonResize` carries no untested conditional — mirrors
/// `OutgoingInputRoute` / `PasteInterception`.
///
/// A resize is sent only when this panel has a resize target AND the
/// size is at or above the SHARED `TerminalGeometryLimits` floor (R6-M5). The
/// floor serves two purposes: SwiftTerm emits transient tiny sizes (0/1
/// cols/rows) mid-layout that must never reach the daemon, and — the R6-M5
/// bug — any size below the daemon's clamp floor would be silently clamped
/// server-side with no report back (the echo fence suppresses our own
/// `%layout-change`), permanently desyncing SwiftTerm from tmux. Accepted
/// residual: a panel physically below the floor keeps tmux at its last
/// >= floor size; self-heals on the next >= floor resize (see
/// `TerminalGeometryLimits`).
enum TerminalResizeGate {
    static func shouldSend(targetAttached: Bool, cols: Int, rows: Int) -> Bool {
        guard targetAttached else { return false }
        return cols >= TerminalGeometryLimits.minCols && rows >= TerminalGeometryLimits.minRows
    }
}
