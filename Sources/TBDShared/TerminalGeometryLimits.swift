import Foundation

/// The terminal grid limits the app and the daemon share (R6-M5).
///
/// **The floor applies on both transports.** The app sends no `pane.resize`
/// below `minCols`×`minRows` (`TerminalResizeGate`): SwiftTerm emits
/// transient tiny sizes mid-layout, and a degenerate grid must not reach the
/// daemon.
///
/// **The clamp exists only on the control-mode path.**
/// `ControlModeResizeCoordinator` clamps `resize-window` into
/// `minCols`×`minRows`…`maxCols`×`maxRows`. The app and that clamp share
/// one floor because a mismatch desyncs for good: a 10-column size sent
/// against a 20-column floor is clamped to 20, the clamp is never reported
/// back (the echo fence suppresses our own `%layout-change`), and SwiftTerm
/// believes a size tmux never adopted. So the app never sends a size the
/// daemon would floor-clamp, and the clamp stays as a backstop against other
/// clients. Accepted residual: a panel physically narrower or shorter than
/// the floor keeps tmux at (or near) the floor size; SwiftTerm renders the
/// smaller viewport locally and the mismatch self-heals on the next >= floor
/// resize. A sub-20-column terminal is not a usable target for tmux anyway
/// (tmux historically misbehaves on absurd dimensions).
///
/// The holder transport has no daemon-side clamp:
/// `HolderRegistry.applyViewerResize` applies whatever size arrives.
public enum TerminalGeometryLimits {
    /// Smallest width/height the app sends a `pane.resize` for, on either
    /// transport. On the control-mode path it is also the smallest size the
    /// daemon accepts un-clamped.
    public static let minCols = 20
    public static let minRows = 5
    /// Upper clamp bounds, read only by the control-mode daemon-side clamp
    /// (a huge size wedges tmux; the app never legitimately produces one).
    /// The holder path does not clamp.
    public static let maxCols = 500
    public static let maxRows = 300
}
