import CoreGraphics

/// Decides what happens to a scroll-wheel event that arrives over a
/// tmux-attached terminal, and where in the grid a forwarded event lands.
///
/// The routing rule this type exists to enforce: a wheel event over a visible,
/// tmux-attached terminal is **never** handed back to AppKit. TBD turns
/// SwiftTerm's own mouse reporting off (`allowMouseReporting = false`) and
/// forwards wheel motion to tmux itself. SwiftTerm's `scrollWheel`, reached by
/// any event we decline, then falls back to its alternate-screen behaviour and
/// translates the wheel into Up/Down cursor keys. tmux runs the outer terminal
/// on the alternate screen, so that fallback always fires, and the agent in the
/// pane reads those keys as typing — Claude Code's composer maps Up to prompt
/// history, so a scroll silently replaces whatever draft was in the box. Every
/// event that is ours is therefore either forwarded as a mouse button or
/// dropped; only events that are not ours pass through.
///
/// The logic is pure so each branch can be tested without an NSView, a window,
/// or a live terminal.
enum TerminalWheelRouting {
    /// What the scroll monitor should do with one event.
    enum Disposition: Equatable {
        /// Not ours: the pointer is elsewhere, an overlay owns the event, or
        /// the event carries no vertical motion at all. Hand it back to AppKit.
        case passThrough
        /// Ours, but tmux has not enabled mouse reporting, so there is nothing
        /// to forward. Drop it rather than letting SwiftTerm see it.
        case swallow
        /// Ours: forward `count` presses of `button` (4 = up, 5 = down) to tmux.
        case forward(button: Int, count: Int)
    }

    /// Classifies one wheel event.
    ///
    /// - Parameters:
    ///   - deltaY: `NSEvent.deltaY` — line-granularity motion.
    ///   - scrollingDeltaY: `NSEvent.scrollingDeltaY` — the point-granularity
    ///     motion SwiftTerm's own override reads. An event with a zero
    ///     `deltaY` and a nonzero `scrollingDeltaY` still becomes cursor keys
    ///     downstream, so it counts as motion here.
    ///   - overlayOpen: whether a SwiftUI overlay is on top of the terminal.
    ///   - pointerInside: whether the pointer is within the terminal's bounds.
    ///   - mouseReportingOn: whether tmux has mouse reporting enabled.
    nonisolated static func disposition(
        deltaY: CGFloat,
        scrollingDeltaY: CGFloat,
        overlayOpen: Bool,
        pointerInside: Bool,
        mouseReportingOn: Bool
    ) -> Disposition {
        guard deltaY != 0 || scrollingDeltaY != 0 else { return .passThrough }
        guard !overlayOpen, pointerInside else { return .passThrough }
        guard mouseReportingOn else { return .swallow }

        let isUp = deltaY != 0 ? deltaY > 0 : scrollingDeltaY > 0
        let count = max(1, Int(abs(deltaY)))
        return .forward(button: isUp ? 4 : 5, count: count)
    }

    /// Converts a view-local point to a grid cell, clamped into the grid.
    ///
    /// Mirrors `TBDTerminalView.gridPosition(atWindowLocation:)`, except that a
    /// point outside the grid resolves to the nearest cell instead of `nil`.
    /// The slack strip below the last row and the sliver right of the last
    /// column are both inside the view's bounds but outside the grid, and a
    /// wheel event there must still be forwarded rather than declined.
    nonisolated static func clampedGrid(
        localPoint: CGPoint,
        boundsHeight: CGFloat,
        cell: (width: CGFloat, height: CGFloat),
        cols: Int,
        rows: Int
    ) -> (col: Int, row: Int) {
        guard cols > 0, rows > 0, cell.width > 0, cell.height > 0 else { return (0, 0) }

        let rawCol = Int(localPoint.x / cell.width)
        let rawRow = Int((boundsHeight - localPoint.y) / cell.height)
        return (col: min(max(rawCol, 0), cols - 1), row: min(max(rawRow, 0), rows - 1))
    }
}
