import AppKit
import SwiftUI

/// Parsed cell data for one GFM table, extracted from a `Markdown.Table`. Each
/// cell is an already-rendered `NSAttributedString` (inline markdown resolved by
/// the shared visitor), so **bold**, `code`, and links inside cells survive. (#129)
struct TranscriptTableData: Equatable {
    let header: [NSAttributedString]
    let rows: [[NSAttributedString]]

    /// Column count is driven by the header row.
    var columnCount: Int { header.count }
}

/// Renders a `TranscriptTableData` as a bordered grid, mirroring the look of the
/// old MarkdownUI table (`ChatBubbleView`): header row bold, thin cell borders,
/// padded cells. Used as the content of a `TranscriptCardAttachment` because
/// `NSTextTable` does not lay out under STTextView's TextKit 2 layout. (#129)
///
/// Borders are drawn per-cell as a top + leading edge, with one outer border on
/// the whole grid. Interior lines therefore land exactly on the content-sized
/// column/row boundaries (no equal-width approximation) and don't double up.
struct TranscriptTableView: View {
    let data: TranscriptTableData
    let borderColor: Color

    private let cellHPadding: CGFloat = 8
    private let cellVPadding: CGFloat = 4
    private let lineWidth: CGFloat = 1

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(allRows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIndex, cell in
                        cellText(cell)
                            // FIX: stretch each cell to the FULL height of its
                            // grid row (SwiftUI `Grid` sizes a row to its tallest
                            // cell, but a cell's content only occupies its own
                            // intrinsic height). Without `maxHeight: .infinity`,
                            // the top/leading border overlays — anchored to the
                            // cell's content box, not the row box — stopped at the
                            // content and didn't reach the row's bottom, so a
                            // shorter cell beside a taller one showed a border that
                            // ended mid-row. Filling the cell makes every border in
                            // a row span the full row height. (#129)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .overlay(alignment: .top) {
                                if rowIndex > 0 { Rectangle().fill(borderColor).frame(height: lineWidth) }
                            }
                            .overlay(alignment: .leading) {
                                if colIndex > 0 { Rectangle().fill(borderColor).frame(width: lineWidth) }
                            }
                    }
                }
            }
        }
        .overlay(Rectangle().stroke(borderColor, lineWidth: lineWidth))
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Header row first, then body rows — so per-cell top/leading borders draw
    /// every interior divider exactly once.
    private var allRows: [[NSAttributedString]] { [data.header] + data.rows }

    private func cellText(_ cell: NSAttributedString) -> some View {
        Text(AttributedString(cell))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, cellHPadding)
            .padding(.vertical, cellVPadding)
    }
}
