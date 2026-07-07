import Foundation

/// ONE shared geometry envelope for control-mode window sizing (R6-M5).
///
/// Two independent guards used to disagree: the app's resize gate refused
/// only degenerate mid-layout sizes (< 2), while the daemon clamped
/// `resize-window` into 20×5…500×300. A panel sized between the two floors
/// permanently desynced: the app kept sending e.g. 10 cols, the daemon
/// clamped to 20, the clamp was never reported back (the echo fence
/// suppresses our own `%layout-change`), and SwiftTerm believed a size tmux
/// never adopted. Both sides now share these constants — the app never
/// SENDS a size the daemon would floor-clamp, and the daemon keeps clamping
/// as a backstop against other/older clients.
///
/// Accepted residual: a panel physically narrower/shorter than the floor
/// keeps tmux at (or near) the floor size — SwiftTerm renders the smaller
/// viewport locally and the mismatch self-heals on the next >= floor
/// resize. That is strictly better than the pre-fix silent desync, and a
/// sub-20-column terminal is not a usable target for tmux anyway
/// (tmux historically misbehaves on absurd dimensions).
public enum ControlModeGeometry {
    /// Smallest width/height the app will send AND the daemon will accept
    /// un-clamped. Below this the app's gate refuses to send.
    public static let minCols = 20
    public static let minRows = 5
    /// Upper clamp bounds — daemon-side backstop only (a huge size wedges
    /// tmux; the app never legitimately produces one).
    public static let maxCols = 500
    public static let maxRows = 300
}
