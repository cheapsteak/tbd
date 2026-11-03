import CoreGraphics

/// Sizing arithmetic for the sidebar's pinned dock. Pure, so the clamping rules
/// are testable without instantiating any view — the view just applies the
/// number this returns.
enum PinnedDockMetrics {
    /// One dock row is exactly one sidebar row, so the dock reads the row's own
    /// fixed height rather than keeping a copy that could drift from it.
    static let rowHeight: CGFloat = SidebarNativeMetrics.rowHeight

    /// Hard ceiling on visible dock rows before it scrolls internally.
    static let maxRows: Int = 5

    /// The dock never takes more than this share of the sidebar, so the repo
    /// list keeps a known floor however many worktrees are pinned.
    static let maxSidebarFraction: CGFloat = 0.4

    /// Height for a dock holding `rowCount` rows inside a sidebar of
    /// `availableHeight`. Zero rows means the dock is absent entirely.
    static func height(rowCount: Int, availableHeight: CGFloat) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        let wanted = CGFloat(rowCount) * rowHeight
        let rowCap = CGFloat(maxRows) * rowHeight
        let fractionCap = max(0, availableHeight) * maxSidebarFraction
        return min(wanted, rowCap, fractionCap)
    }
}
