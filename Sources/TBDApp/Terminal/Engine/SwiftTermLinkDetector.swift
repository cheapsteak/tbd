import Foundation
import SwiftTerm
import TBDGhosttyTerminal

/// SwiftTerm's own link detection, for the libghostty engine, which has none: the URL or path the
/// SwiftTerm engine finds on the same screen, soft-wrapped across rows or not. A ⌘-click opens it,
/// and a ⌘-hover underlines the cells it covers.
///
/// The SwiftTerm engine's view finds what a mouse-up lands on with `Terminal.link(at:mode:)` and
/// hands it to `requestOpenLink`, and underlines a ⌘-hover's match, row by row, from the cells
/// SwiftTerm's own `linkMatch(at:mode:)` reports. The matcher behind both (Ghostty's URL and path
/// pattern, and the rule for which rows a soft wrap or an editor's hard wrap joins into one line)
/// is private to SwiftTerm, and `link(at:mode:)`, which answers with the match's text alone, is the
/// one way in. So the rows the libghostty view read, those on view and those its lines run on into,
/// are written into a headless SwiftTerm terminal as wide as the grid and as tall as the rows read,
/// each character at its column and each soft wrap made the way a program makes one, by printing on
/// past the end of the row, and SwiftTerm is asked about the cells.
enum SwiftTermLinkDetector {
    /// The link SwiftTerm finds under the pressed cell of `clicked`, or nil.
    static func link(in clicked: GhosttyClickedText) -> String? {
        guard holds(clicked) else { return nil }
        return Screen(rows: clicked.rows, columns: clicked.columns)?
            .link(column: clicked.column, row: clicked.row)
    }

    /// The link SwiftTerm finds under the hovered cell of `hovered`, with the cells it covers, or
    /// nil. Rows are those of `hovered.rows`.
    static func textLink(in hovered: GhosttyClickedText) -> GhosttyTextLink? {
        guard holds(hovered) else { return nil }
        return Screen(rows: hovered.rows, columns: hovered.columns)?
            .textLink(column: hovered.column, row: hovered.row)
    }

    /// Whether the cell `text` names is on its screen.
    private static func holds(_ text: GhosttyClickedText) -> Bool {
        text.columns > 0 && text.rows.indices.contains(text.row) && (0..<text.columns).contains(text.column)
    }

    /// Writes `rows` into `terminal`, a new one their size, so that its cells hold the same
    /// characters at the same columns and its rows wrap where theirs did. A cell with no text is
    /// left as SwiftTerm leaves one, never written; the second half of a wide character is the
    /// character's own.
    private static func write(_ rows: [GhosttyClickedText.Row], into terminal: SwiftTerm.Terminal) {
        // Whether the cursor waits to wrap past the last column of the row just written.
        var waitsToWrap = false
        for (index, row) in rows.enumerated() {
            let wraps = row.isWrapContinuation && waitsToWrap
            var bytes = ""
            // The column the cursor is known to sit at, if any.
            var cursorColumn: Int?
            for (column, character) in row.text.enumerated() where character != "\0" {
                if !(wraps && column == 0), cursorColumn != column {
                    bytes += "\u{1b}[\(index + 1);\(column + 1)H"
                }
                bytes.append(character)
                // An ASCII character is one column wide in both terminals; another can be two in
                // one and one in the other, so the next character is placed after it explicitly.
                cursorColumn = character.isASCII ? column + 1 : nil
            }
            terminal.feed(text: bytes)
            // SwiftTerm's cursor sits at `cols` once a character lands in the last column.
            let cursor = terminal.getCursorLocation()
            waitsToWrap = cursor.y == index && cursor.x >= terminal.cols
        }
    }

    // MARK: - A screen written once

    /// One screen's rows written into a headless SwiftTerm terminal, which can then be asked about
    /// any of its cells without writing them again.
    final class Screen {
        typealias Span = GhosttyTextLink.Span

        let rows: [GhosttyClickedText.Row]
        let columns: Int
        /// Each row's characters, one per column of the grid, `"\0"` for a cell with no text.
        private let cells: [[Character]]
        private let terminal: SwiftTerm.Terminal
        /// The terminal's delegate. `Terminal` holds its delegate weakly, so the screen keeps it.
        private let delegate: any TerminalDelegate

        /// nil for a screen with no rows or no columns.
        init?(rows: [GhosttyClickedText.Row], columns: Int) {
            guard columns > 0, !rows.isEmpty else { return nil }
            let delegate = SilentDelegate()
            let terminal = SwiftTerm.Terminal(
                delegate: delegate, options: TerminalOptions(cols: columns, rows: rows.count, scrollback: 0))
            terminal.terminalLock.withLock { SwiftTermLinkDetector.write(rows, into: terminal) }
            self.rows = rows
            self.columns = columns
            self.cells = rows.map { Array($0.text.prefix(columns)) }
            self.terminal = terminal
            self.delegate = delegate
        }

        /// The link SwiftTerm finds under the cell at `column`, `row`, or nil.
        func link(column: Int, row: Int) -> String? {
            guard holds(column: column, row: row) else { return nil }
            return terminal.terminalLock.withLock { lookup(column: column, row: row) }
        }

        /// The link SwiftTerm finds under the cell at `column`, `row`, with the cells it covers,
        /// or nil.
        ///
        /// SwiftTerm answers with the same link for every cell of its match and for no other, so
        /// the cells are found by asking about the cells around: along the row while the answer
        /// stays the same, then on across each row end SwiftTerm joins, a soft wrap or an editor's
        /// hard wrap, while the link has characters left. As SwiftTerm joins two rows, the upper
        /// one's text runs to its last written cell and the lower one's starts at its first cell
        /// that is neither empty nor blank, so a crossing goes between those two cells.
        func textLink(column: Int, row: Int) -> GhosttyTextLink? {
            guard holds(column: column, row: row) else { return nil }
            return terminal.terminalLock.withLock { () -> GhosttyTextLink? in
                guard let link = lookup(column: column, row: row) else { return nil }
                let length = link.count
                var spans = [Span(row: row, columns: run(onRow: row, around: column, answering: link))]
                var found = characterCount(of: spans[0])
                // A crossing may take no more characters than the link has left. The same link
                // printed again at the edge of a row SwiftTerm does not join, as in a list, would
                // otherwise be taken for this one's continuation.
                while found < length, let above = continuation(above: spans[0], answering: link),
                      found + characterCount(of: above) <= length {
                    spans.insert(above, at: 0)
                    found += characterCount(of: above)
                }
                while found < length, let below = continuation(below: spans[spans.endIndex - 1], answering: link),
                      found + characterCount(of: below) <= length {
                    spans.append(below)
                    found += characterCount(of: below)
                }
                return GhosttyTextLink(text: link, spans: spans)
            }
        }

        // MARK: Inside the terminal's lock

        /// SwiftTerm's answer for the cell at `column`, `row`.
        private func lookup(column: Int, row: Int) -> String? {
            terminal.link(at: .screen(Position(col: column, row: row)), mode: .explicitAndImplicit)
        }

        /// The cells on `row` around `column` that SwiftTerm answers with `link`.
        private func run(onRow row: Int, around column: Int, answering link: String) -> Range<Int> {
            var start = column
            while start > 0, lookup(column: start - 1, row: row) == link { start -= 1 }
            var end = column + 1
            while end < columns, lookup(column: end, row: row) == link { end += 1 }
            return start..<end
        }

        /// The cells answering `link` on the row above `span`'s, when `span` starts its row's text
        /// and the row above's text ends in `link`.
        private func continuation(above span: Span, answering link: String) -> Span? {
            let upper = span.row - 1
            guard upper >= 0, let start = textStart(ofRow: span.row), span.columns.lowerBound <= start,
                  let end = textEnd(ofRow: upper), lookup(column: end - 1, row: upper) == link else { return nil }
            return Span(row: upper, columns: run(onRow: upper, around: end - 1, answering: link))
        }

        /// The cells answering `link` on the row below `span`'s, when `span` ends its row's text
        /// and the row below's text starts in `link`.
        private func continuation(below span: Span, answering link: String) -> Span? {
            let lower = span.row + 1
            guard lower < rows.count, let end = textEnd(ofRow: span.row), span.columns.upperBound >= end,
                  let start = textStart(ofRow: lower), lookup(column: start, row: lower) == link else { return nil }
            return Span(row: lower, columns: run(onRow: lower, around: start, answering: link))
        }

        // MARK: The rows' text

        private func holds(column: Int, row: Int) -> Bool {
            rows.indices.contains(row) && (0..<columns).contains(column)
        }

        /// The column of `row`'s first cell that is neither empty nor blank, or nil for a row with
        /// none.
        private func textStart(ofRow row: Int) -> Int? {
            cells[row].firstIndex { $0 != "\0" && !$0.isWhitespace }
        }

        /// The column after `row`'s last written cell, or nil for a row with none.
        private func textEnd(ofRow row: Int) -> Int? {
            cells[row].lastIndex { $0 != "\0" }.map { $0 + 1 }
        }

        /// The characters `span` covers. The second half of a wide character holds none.
        private func characterCount(of span: Span) -> Int {
            let row = cells[span.row]
            return row[span.columns.clamped(to: 0..<row.count)].filter { $0 != "\0" }.count
        }
    }

    // MARK: - The ⌘-hover's lookups

    /// The ⌘-hover's lookups for one terminal. A hover asks about every cell the pointer crosses,
    /// so the screen last read stays written, and the link last found is kept: the screen is
    /// written again only once it changed, and SwiftTerm is asked nothing while the pointer stays
    /// on the link it found.
    final class HoverLinks {
        private var screen: Screen?
        private var found: GhosttyTextLink?
        /// How many screens have been written. Tests only.
        private(set) var screensWritten = 0

        init() {}

        /// `SwiftTermLinkDetector.textLink(in:)`, from what is kept where it can be.
        func textLink(in hovered: GhosttyClickedText) -> GhosttyTextLink? {
            guard SwiftTermLinkDetector.holds(hovered) else { return nil }
            if let screen, screen.columns == hovered.columns, screen.rows == hovered.rows {
                if let found, found.spans.contains(where: {
                    $0.row == hovered.row && $0.columns.contains(hovered.column)
                }) {
                    return found
                }
            } else {
                screen = Screen(rows: hovered.rows, columns: hovered.columns)
                if screen != nil { screensWritten += 1 }
            }
            found = screen?.textLink(column: hovered.column, row: hovered.row)
            return found
        }
    }

    /// The headless terminal's delegate. It answers nothing: the terminal is read, never asked.
    private final class SilentDelegate: TerminalDelegate {
        func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {}
    }
}
