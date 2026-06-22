import AppKit
import Markdown

/// Renders a GFM `Markdown.Table` node into an `NSAttributedString` using
/// `NSTextTable` / `NSTextTableBlock` so TextKit 2 lays out cells in a grid. (#129)
@MainActor
enum MarkdownTable {
    /// Converts a parsed `Markdown.Table` into a fully attributed string.
    ///
    /// - Parameters:
    ///   - table:  The swift-markdown `Table` node.
    ///   - theme:  Visual spec (border color, header-bold flag, body font/color).
    ///   - render: Closure that converts any `Markup` child into an `NSAttributedString`
    ///             so inline markdown inside cells (bold, code, links) is rendered
    ///             using the same visitor as the rest of the document.
    static func attributed(
        _ table: Markdown.Table,
        theme: TranscriptTextTheme,
        render: (any Markup) -> NSAttributedString
    ) -> NSAttributedString {
        // Count columns from the header row.
        let columnCount = table.head.childCount
        guard columnCount > 0 else { return NSAttributedString() }

        let nsTable = NSTextTable()
        nsTable.numberOfColumns = columnCount
        nsTable.layoutAlgorithm = .automaticLayoutAlgorithm

        let out = NSMutableAttributedString()

        // Header row (row index 0).
        var rowIndex = 0
        for (colIndex, cell) in table.head.cells.enumerated() {
            out.append(cellAttributedString(
                cell: cell,
                rowIndex: rowIndex,
                colIndex: colIndex,
                nsTable: nsTable,
                isHeader: true,
                theme: theme,
                render: render
            ))
        }
        rowIndex += 1

        // Body rows.
        for row in table.body.rows {
            for (colIndex, cell) in row.cells.enumerated() {
                out.append(cellAttributedString(
                    cell: cell,
                    rowIndex: rowIndex,
                    colIndex: colIndex,
                    nsTable: nsTable,
                    isHeader: false,
                    theme: theme,
                    render: render
                ))
            }
            rowIndex += 1
        }

        return out
    }

    // MARK: - Private

    private static func cellAttributedString(
        cell: Markdown.Table.Cell,
        rowIndex: Int,
        colIndex: Int,
        nsTable: NSTextTable,
        isHeader: Bool,
        theme: TranscriptTextTheme,
        render: (any Markup) -> NSAttributedString
    ) -> NSAttributedString {
        let block = NSTextTableBlock(
            table: nsTable,
            startingRow: rowIndex,
            rowSpan: 1,
            startingColumn: colIndex,
            columnSpan: 1
        )

        // Border.
        block.setBorderColor(theme.tableBorderColor)
        for edge: NSRectEdge in [.minX, .maxX, .minY, .maxY] {
            block.setWidth(1, type: .absoluteValueType, for: .border, edge: edge)
        }

        // Padding: 4 pt vertical, 8 pt horizontal.
        block.setWidth(4, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(4, type: .absoluteValueType, for: .padding, edge: .maxY)
        block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX)

        // Render cell content through the shared visitor.
        let cellContent = NSMutableAttributedString(attributedString: render(cell))

        // For header cells: merge the bold trait into each run's EXISTING font.
        // Do NOT blanket-replace — that would clobber inline-code monospace fonts.
        if isHeader && theme.tableHeaderBold {
            let full = NSRange(location: 0, length: cellContent.length)
            cellContent.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
                let base = (value as? NSFont) ?? theme.bodyFont
                let desc = base.fontDescriptor.withSymbolicTraits(
                    base.fontDescriptor.symbolicTraits.union(.bold)
                )
                let font = NSFont(descriptor: desc, size: base.pointSize) ?? base
                cellContent.addAttribute(.font, value: font, range: range)
            }
        }

        // Build the paragraph style for this cell block.
        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        style.paragraphSpacing = theme.paragraphSpacing

        let full = NSRange(location: 0, length: cellContent.length)
        cellContent.addAttribute(.paragraphStyle, value: style, range: full)

        // Each cell paragraph ends with a newline.
        cellContent.append(NSAttributedString(string: "\n"))

        return cellContent
    }
}
