import AppKit
import Markdown

/// Extracts cell data from a GFM `Markdown.Table` node into a `TranscriptTableData`
/// of pre-rendered `NSAttributedString` cells. The table is then rendered as a
/// SwiftUI `TranscriptTableView` hosted in a `TranscriptCardAttachment`, because
/// `NSTextTable`/`NSTextTableBlock` is a TextKit 1 construct that STTextView's
/// TextKit 2 `NSTextLayoutManager` does NOT lay out as a grid (it flattens cells
/// into a vertical list). (#129)
@MainActor
enum MarkdownTable {
    /// Converts a parsed `Markdown.Table` into header + body cell data.
    ///
    /// - Parameters:
    ///   - table:  The swift-markdown `Table` node.
    ///   - theme:  Visual spec (header-bold flag, body font/color).
    ///   - render: Closure that converts any `Markup` child into an `NSAttributedString`
    ///             so inline markdown inside cells (bold, code, links) is rendered
    ///             using the same visitor as the rest of the document.
    static func data(
        _ table: Markdown.Table,
        theme: TranscriptTextTheme,
        render: (any Markup) -> NSAttributedString
    ) -> TranscriptTableData {
        let header = Array(table.head.cells).map { cell in
            cellAttributedString(cell: cell, isHeader: true, theme: theme, render: render)
        }
        let rows = Array(table.body.rows).map { row in
            Array(row.cells).map { cell in
                cellAttributedString(cell: cell, isHeader: false, theme: theme, render: render)
            }
        }
        return TranscriptTableData(header: header, rows: rows)
    }

    // MARK: - Private

    private static func cellAttributedString(
        cell: Markdown.Table.Cell,
        isHeader: Bool,
        theme: TranscriptTextTheme,
        render: (any Markup) -> NSAttributedString
    ) -> NSAttributedString {
        let content = NSMutableAttributedString(attributedString: render(cell))
        let full = NSRange(location: 0, length: content.length)

        // Back-fill body font/color onto runs that didn't set their own (mirrors
        // the render-level back-fill) so cells carry concrete attributes when
        // bridged into SwiftUI `AttributedString` for the table view.
        content.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            if value == nil { content.addAttribute(.font, value: theme.bodyFont, range: range) }
        }
        content.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
            if value == nil { content.addAttribute(.foregroundColor, value: theme.bodyColor, range: range) }
        }

        // For header cells: merge the bold trait into each run's EXISTING font.
        // Do NOT blanket-replace — that would clobber inline-code monospace fonts.
        if isHeader && theme.tableHeaderBold {
            content.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
                let base = (value as? NSFont) ?? theme.bodyFont
                let desc = base.fontDescriptor.withSymbolicTraits(
                    base.fontDescriptor.symbolicTraits.union(.bold)
                )
                let font = NSFont(descriptor: desc, size: base.pointSize) ?? base
                content.addAttribute(.font, value: font, range: range)
            }
        }

        return content
    }
}
