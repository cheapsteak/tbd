import Foundation
import TBDShared

/// Pure decision for whether the Coordinator should send a control-mode
/// `pane.resize` for a given proposed geometry (M3.2). Extracted so the gated
/// branch in `sizeChanged` / `scheduleControlModeResize` carries no untested
/// conditional — mirrors `OutgoingInputRoute` / `PasteInterception`.
///
/// A resize is sent only when this panel is control-mode attached AND the
/// size is at or above the SHARED `ControlModeGeometry` floor (R6-M5). The
/// floor serves two purposes: SwiftTerm emits transient tiny sizes (0/1
/// cols/rows) mid-layout that must never reach the daemon, and — the R6-M5
/// bug — any size below the daemon's clamp floor would be silently clamped
/// server-side with no report back (the echo fence suppresses our own
/// `%layout-change`), permanently desyncing SwiftTerm from tmux. Accepted
/// residual: a panel physically below the floor keeps tmux at its last
/// >= floor size; self-heals on the next >= floor resize (see
/// `ControlModeGeometry`).
enum ControlModeResizeGate {
    static func shouldSend(controlModeAttached: Bool, cols: Int, rows: Int) -> Bool {
        guard controlModeAttached else { return false }
        return cols >= ControlModeGeometry.minCols && rows >= ControlModeGeometry.minRows
    }
}
