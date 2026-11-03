import CoreGraphics

/// The height of the status bar at the foot of the split's content pane
/// (`StatusBarView`), which sits on the window's bottom edge and centres its
/// content vertically in it. The sidebar column beside it has no bar of its
/// own: the outline and the dock run to the window's bottom edge.
///
/// Spec: docs/specs/2026-11-01-appkit-window-chrome-design.md, "Window
/// structure".
enum WindowBottomBarMetrics {
    /// Fits the status bar's tallest content, `OpenInEditorButton`'s 16 pt
    /// icons with 4 pt padding, with 4 pt to spare above and below.
    static let height: CGFloat = 32
}
