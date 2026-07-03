import Foundation

/// Pure decision for whether the Coordinator should send a control-mode
/// `pane.resize` for a given proposed geometry (M3.2). Extracted so the gated
/// branch in `sizeChanged` / `scheduleControlModeResize` carries no untested
/// conditional — mirrors `OutgoingInputRoute` / `PasteInterception`.
///
/// A resize is sent only when this panel is control-mode attached AND the size
/// is non-degenerate: SwiftTerm emits transient tiny sizes (0/1 cols/rows) mid
/// layout, and the daemon is the sole size authority (addendum §4), so shipping
/// those would briefly wedge the window at a garbage size before the next tick.
enum ControlModeResizeGate {
    /// Smallest cols/rows we will forward. Below this is a mid-layout artifact.
    static let minDimension = 2

    static func shouldSend(controlModeAttached: Bool, cols: Int, rows: Int) -> Bool {
        guard controlModeAttached else { return false }
        return cols >= minDimension && rows >= minDimension
    }
}
