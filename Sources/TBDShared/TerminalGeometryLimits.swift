import Foundation

/// The smallest terminal grid the app reports to the daemon.
///
/// The app sends no `pane.resize` below `minCols`×`minRows`
/// (`TerminalResizeGate`): SwiftTerm emits transient tiny sizes mid-layout,
/// and a degenerate grid must not reach the daemon. A holder attach applies
/// the same floor to the grid it asks the daemon to write its snapshot at.
///
/// The daemon does not clamp: `HolderRegistry.applyViewerResize` applies
/// whatever size arrives.
public enum TerminalGeometryLimits {
    /// Smallest width/height the app sends a `pane.resize` for.
    public static let minCols = 20
    public static let minRows = 5
}
