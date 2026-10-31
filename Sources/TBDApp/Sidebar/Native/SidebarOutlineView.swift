import AppKit

/// Geometry the native sidebar's outline, row views and cells share, so a
/// header, a row and the guide lines beneath it agree on where a column is.
///
/// The insets are `SidebarHeaderMetrics`' values — the `listRowInsets` the
/// SwiftUI rows carry — measured from `listEdgeInset`, which stands in for the
/// SwiftUI `List`'s own leading margin. That margin is an estimate; the render
/// harness that draws both paths side by side is where it gets tuned.
enum SidebarNativeMetrics {
    /// Each nesting level adds this much, as `WorktreeRowView`'s
    /// `indentLevel * 16` does.
    static let indentation: CGFloat = 16

    /// Where the SwiftUI list's row content starts before any row inset.
    static let listEdgeInset: CGFloat = 8

    /// A guide line's offset into its level's indentation step: the line runs
    /// down the gutter under that level's leading icon.
    static let guideLineOffset: CGFloat = 8

    /// Where a section header's chrome starts: `headerRowLeadingInset`.
    static var headerContentInset: CGFloat {
        listEdgeInset + SidebarHeaderMetrics.headerRowLeadingInset
    }

    /// Where a depth-0 row's content starts: `childRowLeadingInset`. Rows,
    /// group headers and the scratch prompt all hang from it.
    static func rowContentInset(chevronBeforeTitle: Bool) -> CGFloat {
        listEdgeInset + SidebarHeaderMetrics.childRowLeadingInset(chevronBeforeProjectName: chevronBeforeTitle)
    }
}

/// The native sidebar's `NSOutlineView`.
///
/// Today a section header and the top-level rows beneath it share a leading
/// edge, and each nesting level adds 16 pt, so a row's visual depth is its
/// outline level minus one. `frameOfCell(atColumn:row:)` places every level
/// from 1 down one indentation step to the left of where `NSOutlineView` would
/// put it — level `L` at `(L - 1) * 16`, level 0 at the column's edge — and
/// each cell then insets its own content the way the SwiftUI row's
/// `listRowInsets` do. The native disclosure triangle is hidden; headers draw
/// the SwiftUI path's chevrons themselves.
final class SidebarOutlineView: NSOutlineView {
    /// Kept alive as long as the outline: the tracker owns the outline's one
    /// tracking area, and a tracking area does not retain its owner.
    var hoverTracker: SidebarHoverTracker?

    /// The context menu for a row, built when the menu is asked for. Nil
    /// rows — group headers, provider headers, the scratch prompt — show none.
    var contextMenuProvider: ((Int) -> NSMenu?)?

    /// The row a drag's mouse-down landed on, recorded by
    /// `canDragRows(with:at:)`: its kind decides what the drag carries when
    /// the selection mixes scratch rows and worktrees. Nil once the drag ends.
    var dragOrigin: SidebarNodeID?

    /// Runs when a drag leaves the outline, concludes over it or ends: the
    /// drop's insertion line and nest highlight clear.
    var onDropFeedbackEnded: (() -> Void)?

    /// The row's menu, shown through `super` so the outline draws its usual
    /// highlight around the right-clicked row. The outline does not override
    /// `mouseDown`: rows select and drag natively.
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        menu = row >= 0 ? contextMenuProvider?(row) : nil
        guard menu != nil else { return nil }
        return super.menu(for: event)
    }

    // MARK: Drag and drop

    /// A press on a row's pin toggle or nested `+` tracks the button and
    /// never starts a drag; a press anywhere else in the row can. The row the
    /// press landed on is recorded as the drag's origin.
    ///
    /// - Parameters:
    ///   - rowIndexes: the rows the drag would carry: the selection when the
    ///     pressed row is selected, otherwise the pressed row alone.
    ///   - mouseDownPoint: in the outline's coordinates.
    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        dragOrigin = nil
        if isOnButton(mouseDownPoint) { return false }
        if let row = pressedRow(at: mouseDownPoint, among: rowIndexes) {
            dragOrigin = (item(atRow: row) as? SidebarItem)?.id
        }
        return super.canDragRows(with: rowIndexes, at: mouseDownPoint)
    }

    /// The pressed row, which is always among the rows a drag would carry:
    /// the row under the point, or the lone row when the point names none of
    /// them.
    private func pressedRow(at point: NSPoint, among rows: IndexSet) -> Int? {
        let underPoint = row(at: point)
        if underPoint >= 0, rows.contains(underPoint) { return underPoint }
        return rows.count == 1 ? rows.first : nil
    }

    /// Rows only ever move. A modifier key held mid-drag would otherwise
    /// narrow the drag's `.move` mask — ⌥ to a copy, ⌃ to a link, ⌘ to a
    /// generic operation — leaving nothing the sidebar accepts, and the drop
    /// would silently stop working.
    override func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    /// How many times `setDropItem(_:dropChildIndex:)` ran, and the position
    /// the last call named: what a test reads to prove a proposal is
    /// retargeted only when the drop policy's answer differs. AppKit's own
    /// calls, if any, count too.
    private(set) var dropRetargetCount = 0
    private(set) var lastDropRetarget: (item: SidebarNodeID?, childIndex: Int)?

    override func setDropItem(_ item: Any?, dropChildIndex index: Int) {
        dropRetargetCount += 1
        lastDropRetarget = (item: (item as? SidebarItem)?.id, childIndex: index)
        super.setDropItem(item, dropChildIndex: index)
    }

    /// Whether `point`, in the outline's coordinates, lands on a button
    /// inside a row.
    func isOnButton(_ point: NSPoint) -> Bool {
        guard let superview else { return false }
        var view = hitTest(convert(point, to: superview))
        while let current = view, current !== self {
            if current is NSButton { return true }
            view = current.superview
        }
        return false
    }

    // The outline draws no drop feedback of its own
    // (`draggingDestinationFeedbackStyle = .none`); the controller draws it
    // from the drop policy's answer, and these clear it. Each passes the
    // message on first, when `NSOutlineView` implements it.

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if Self.inheritsDragMessage(#selector(NSDraggingDestination.draggingExited(_:))) {
            super.draggingExited(sender)
        }
        onDropFeedbackEnded?()
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        if Self.inheritsDragMessage(#selector(NSDraggingDestination.concludeDragOperation(_:))) {
            super.concludeDragOperation(sender)
        }
        onDropFeedbackEnded?()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        if Self.inheritsDragMessage(#selector(NSDraggingDestination.draggingEnded(_:))) {
            super.draggingEnded(sender)
        }
        onDropFeedbackEnded?()
    }

    /// `NSDraggingDestination`'s methods are optional, so `super` may not
    /// implement one; sending it anyway would raise.
    private static func inheritsDragMessage(_ selector: Selector) -> Bool {
        NSOutlineView.instancesRespond(to: selector)
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        .zero
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let frame = super.frameOfCell(atColumn: column, row: row)
        guard row >= 0, row < numberOfRows, let outlineColumn = outlineTableColumn,
              column == tableColumns.firstIndex(of: outlineColumn) else { return frame }
        let depth = max(level(forRow: row) - 1, 0)
        let columnRect = rect(ofColumn: column)
        let x = columnRect.minX + CGFloat(depth) * indentationPerLevel
        return NSRect(x: x, y: frame.minY, width: max(columnRect.maxX - x, 0), height: frame.height)
    }
}
