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
