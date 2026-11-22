import AppKit
import SwiftUI

/// The AppKit view behind `TablePreviewView`: one `NSScrollView` holding one
/// view-based `NSTableView` that draws a `DelimitedTable`, with the header
/// row as column titles pinned above the scrolling rows.
///
/// The table asks only for the rows in view, so 100,000 rows scroll as fast
/// as ten. Each cell is a plain `NSTextField` label the table reuses; no
/// SwiftUI view is hosted in a cell.
@MainActor
final class TableHostView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let minColumnWidth: CGFloat = 48
    static let maxColumnWidth: CGFloat = 320
    /// The most rows, after the header row, a column's starting width is
    /// measured from. A wide table measures fewer: see `sampledRowCount`.
    static let measuredRowSample = 200
    /// The most values the starting widths are measured from, across all
    /// columns, so a table of 1,000 columns measures 20 rows.
    static let measurementBudget = 20_000
    /// A value longer than this many characters shows only its first this
    /// many and "…". A text field lays out its whole string each time it is
    /// drawn, so a cell holding megabytes would stall scrolling.
    nonisolated static let maxDisplayedCharacters = 1_000
    /// A value is also cut where its shown part would pass this many bytes
    /// of UTF-8. One character can carry any number of combining marks, so
    /// a count of characters alone does not bound what a cell lays out.
    nonisolated static let maxDisplayedUTF8Bytes = maxDisplayedCharacters * 4
    /// The system font with fixed-width digits, so numbers in a column line up.
    static let cellFont: NSFont = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    let scrollView: NSScrollView
    let tableView: NSTableView

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("TableCell")
    private static let columnIdentifierPrefix = "col"
    /// The narrowest a user can drag a column.
    private static let columnMinWidth: CGFloat = 24
    /// One line of `cellFont` with room above and below. A custom row size,
    /// so the table never restyles the cells' font for a system row size.
    private static let rowHeight: CGFloat = 20
    /// Room a column keeps beside its widest measured text: the cell's
    /// insets and the text field's own margins.
    private static let columnPadding: CGFloat = 16
    /// A value longer than this many bytes of UTF-8 is taken to reach
    /// `maxColumnWidth` without being laid out. The byte count is known
    /// without walking the string (`utf8.count` is constant time for a native
    /// string, where `utf16.count` walks a non-ASCII one), and it is never
    /// smaller than the UTF-16 count. At 12 pt, text this long fits under the
    /// clamp only when its glyphs average under 1 pt for each byte they take:
    /// under 1 pt for an ASCII letter, under 3 pt for a 4-byte emoji, far
    /// narrower than the font draws either. So laying out its display string,
    /// up to `maxDisplayedCharacters` long, would spend main-actor time to
    /// learn nothing.
    private static let measuredLengthLimit = 400

    /// The titles and column count the current columns were built for.
    private struct ColumnKey: Equatable {
        let titles: [String]
        let columnCount: Int
    }

    private var columnKey: ColumnKey?
    private var rows: [[String]] = []

    init() {
        scrollView = NSScrollView(frame: .zero)
        tableView = NSTableView(frame: .zero)
        super.init(frame: .zero)

        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = Self.rowHeight
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // Autoresizing rather than constraints, so the scroll view always
        // fills whatever size SwiftUI gives this view.
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Rebuilds columns only when `titles` (or column count) differ from the
    /// shown table; always replaces the rows and calls `reloadData()`.
    ///
    /// So a file rewritten with the same header keeps the widths the user
    /// dragged the columns to, and the scroll position.
    func show(_ table: DelimitedTable) {
        rows = table.rows
        let key = ColumnKey(titles: table.titles, columnCount: table.columnCount)
        if key != columnKey {
            columnKey = key
            rebuildColumns(for: table)
        }
        tableView.reloadData()
    }

    /// The first `maxDisplayedCharacters` characters of `value`, cut sooner,
    /// between two Unicode scalars, where they would pass
    /// `maxDisplayedUTF8Bytes` bytes of UTF-8; then "…" when anything was
    /// cut. `\r\n`, `\n`, `\r` each → "↵".
    nonisolated static func displayString(_ value: String) -> String {
        // The byte cut walks at most `maxDisplayedUTF8Bytes` bytes, and
        // `prefix` at most that many characters of what it keeps, so a value
        // of megabytes costs no more than one at the limits, even when it is
        // a single character of a million combining marks.
        let (bounded, isByteCut) = utf8Prefix(of: value)
        let head = bounded.prefix(maxDisplayedCharacters)
        let isCut = isByteCut || head.endIndex != bounded.endIndex
        guard head.utf8.contains(where: { $0 == 0x0A || $0 == 0x0D }) else {
            return isCut ? String(head) + "…" : value
        }
        var result = ""
        result.reserveCapacity(head.utf8.count + 3)
        for character in head {
            switch character {
            case "\r\n", "\n", "\r":
                result.append("↵")
            default:
                result.append(character)
            }
        }
        if isCut {
            result.append("…")
        }
        return result
    }

    /// `value`'s longest run of whole Unicode scalars from the start that
    /// fits in `maxDisplayedUTF8Bytes` bytes of UTF-8, and whether that is
    /// shorter than `value`. The cut falls between two scalars, so the result
    /// is always valid Unicode, though it may end partway through a
    /// character's combining marks.
    private nonisolated static func utf8Prefix(of value: String) -> (prefix: String, isCut: Bool) {
        // Constant time for a native string, which every parsed value is.
        guard value.utf8.count > maxDisplayedUTF8Bytes else { return (value, false) }
        let scalars = value.unicodeScalars
        var end = scalars.startIndex
        var size = 0
        while end != scalars.endIndex {
            let width = Unicode.UTF8.width(scalars[end])
            if size + width > maxDisplayedUTF8Bytes { break }
            size += width
            scalars.formIndex(after: &end)
        }
        return (String(scalars[..<end]), true)
    }

    /// How many rows, after the header row, a table of `columnCount` columns
    /// measures: `measuredRowSample`, or fewer when that many rows would hold
    /// more than `measurementBudget` values, and always at least one.
    static func sampledRowCount(columnCount: Int) -> Int {
        min(measuredRowSample, max(1, measurementBudget / max(columnCount, 1)))
    }

    /// Per column: max text width of title and the first
    /// `sampledRowCount(columnCount:)` rows' display strings in `cellFont`,
    /// plus 16 pt padding, clamped.
    static func columnWidths(for table: DelimitedTable) -> [CGFloat] {
        let count = table.columnCount
        guard count > 0 else { return [] }
        // Text this wide already reaches the clamp, so a column there needs
        // no more measuring.
        let enough = maxColumnWidth - columnPadding
        var widest = [CGFloat](repeating: 0, count: count)
        for (index, title) in table.titles.prefix(count).enumerated() {
            widest[index] = textWidth(of: title, enough: enough)
        }
        for row in table.rows.prefix(sampledRowCount(columnCount: count)) {
            for (index, value) in row.prefix(count).enumerated()
            where widest[index] < enough && !value.isEmpty {
                widest[index] = max(widest[index], textWidth(of: value, enough: enough))
            }
        }
        return widest.map { width in
            min(max((width + columnPadding).rounded(.up), minColumnWidth), maxColumnWidth)
        }
    }

    // MARK: NSTableViewDataSource and NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Self.columnIndex(of: tableColumn.identifier) else { return nil }
        let cell = (tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? NSTableCellView)
            ?? Self.makeCell()
        var value = ""
        if rows.indices.contains(row) {
            let fields = rows[row]
            if column < fields.count {
                value = Self.displayString(fields[column])
            }
        }
        cell.textField?.stringValue = value
        return cell
    }

    // MARK: Building

    private func rebuildColumns(for table: DelimitedTable) {
        for column in tableView.tableColumns {
            tableView.removeTableColumn(column)
        }
        let widths = Self.columnWidths(for: table)
        for index in 0..<table.columnCount {
            let column = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier("\(Self.columnIdentifierPrefix)\(index)"))
            column.title = index < table.titles.count ? Self.displayString(table.titles[index]) : ""
            column.minWidth = Self.columnMinWidth
            column.width = widths[index]
            column.isEditable = false
            // Only the last column also autoresizes: with
            // `lastColumnOnlyAutoresizingStyle` it takes the width the other
            // columns leave, and a column without `.autoresizingMask` is
            // never autoresized.
            var resizing: NSTableColumn.ResizingOptions = .userResizingMask
            if index == table.columnCount - 1 {
                resizing.insert(.autoresizingMask)
            }
            column.resizingMask = resizing
            tableView.addTableColumn(column)
        }
    }

    private static func makeCell() -> NSTableCellView {
        let cell = NSTableCellView(frame: .zero)
        cell.identifier = cellIdentifier
        let field = NSTextField(labelWithString: "")
        field.font = cellFont
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.allowsExpansionToolTips = true
        field.cell?.truncatesLastVisibleLine = true
        // The field's width comes from the column, never from its text, so a
        // long value truncates instead of pushing against the constraints.
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// The column index an identifier of the form `col<index>` names.
    private static func columnIndex(of identifier: NSUserInterfaceItemIdentifier) -> Int? {
        let raw = identifier.rawValue
        guard raw.hasPrefix(columnIdentifierPrefix) else { return nil }
        return Int(raw.dropFirst(columnIdentifierPrefix.count))
    }

    /// The width of `value`'s display string in `cellFont`, or `enough` for a
    /// value too long to be narrower than that.
    private static func textWidth(of value: String, enough: CGFloat) -> CGFloat {
        guard value.utf8.count <= measuredLengthLimit else { return enough }
        let shown = displayString(value) as NSString
        return shown.size(withAttributes: [.font: cellFont]).width
    }
}

/// Shows a `DelimitedTable` in a native `NSTableView` (`TableHostView`).
struct TablePreviewView: NSViewRepresentable {
    let table: DelimitedTable
    /// Changes each time a new load finishes; `updateNSView` calls `show`
    /// only when it differs from the last one shown, so unrelated SwiftUI
    /// updates never reload 100k rows.
    let loadID: Int

    @MainActor
    final class Coordinator {
        var shownLoadID: Int?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TableHostView {
        let host = TableHostView()
        host.show(table)
        context.coordinator.shownLoadID = loadID
        return host
    }

    func updateNSView(_ host: TableHostView, context: Context) {
        guard context.coordinator.shownLoadID != loadID else { return }
        context.coordinator.shownLoadID = loadID
        host.show(table)
    }
}
