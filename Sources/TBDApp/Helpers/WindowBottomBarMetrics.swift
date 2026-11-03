import CoreGraphics

/// The main window's two bottom bars share one height: the status bar at the
/// foot of the split's content pane (`StatusBarView`) and the footer at the
/// foot of the sidebar column (`SidebarFooter`). Both bars use it, and both
/// sit on the window's bottom edge, so their tops and centre lines line up
/// across the split. Each centres its content vertically in this height.
///
/// Spec: docs/specs/2026-11-01-appkit-window-chrome-design.md, "Window
/// structure".
enum WindowBottomBarMetrics {
    /// Fits the status bar's tallest content, `OpenInEditorButton`'s 16 pt
    /// icons with 4 pt padding, with 4 pt to spare above and below, and the
    /// footer's 20 pt filter icon and Add Repository label.
    static let height: CGFloat = 32
}
