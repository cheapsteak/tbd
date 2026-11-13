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
        /// How many times SwiftTerm has been asked about a cell. Tests only.
        private(set) var lookups = 0

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
        /// SwiftTerm answers with the link's text alone, and each answer scans the whole line the
        /// cell is on, so the cells are not found by asking about each in turn. The link is found
        /// in the line's text instead, where it covers the cell (`located`), and SwiftTerm is
        /// asked only about the few cells that bear that out. Where they do not, as when its answer
        /// is not the screen's text as written, the cells are found by asking about each
        /// (`walked`).
        func textLink(column: Int, row: Int) -> GhosttyTextLink? {
            guard holds(column: column, row: row) else { return nil }
            return terminal.terminalLock.withLock { () -> GhosttyTextLink? in
                guard let link = lookup(column: column, row: row) else { return nil }
                let spans = located(link, column: column, row: row) ?? walked(link, column: column, row: row)
                return GhosttyTextLink(text: link, spans: spans)
            }
        }

        // MARK: Inside the terminal's lock

        /// SwiftTerm's answer for the cell at `column`, `row`.
        private func lookup(column: Int, row: Int) -> String? {
            lookups += 1
            return terminal.link(at: .screen(Position(col: column, row: row)), mode: .explicitAndImplicit)
        }

        private func lookup(_ cell: Cell) -> String? {
            lookup(column: cell.column, row: cell.row)
        }

        /// The cells of `link` where the text of the line around the cell at `column`, `row` has
        /// it covering that cell, one span per row, or nil when SwiftTerm does not bear that out.
        ///
        /// SwiftTerm must answer with `link` for the first of the cells and the last, and for the
        /// cells either side of each row end they cross that only an editor's hard wrap joins, and
        /// must not for the cell before the first and the cell after the last on their rows. So a
        /// link takes five questions, and two more for each hard wrap it crosses, however long
        /// its line.
        private func located(_ link: String, column: Int, row: Int) -> [Span]? {
            let target = Array(link)
            let length = target.count
            guard length > 0, let (line, offset) = self.line(around: column, row: row, length: length) else { return nil }
            let first = max(0, offset - length + 1)
            let last = min(offset, line.characters.count - length)
            guard first <= last else { return nil }
            candidates: for start in first...last
            where line.characters[start..<(start + length)].elementsEqual(target) {
                let end = start + length - 1
                let head = line.cells[start], tail = line.cells[end]
                guard lookup(head) == link, lookup(tail) == link else { continue }
                if head.column > 0, lookup(column: head.column - 1, row: head.row) == link { continue }
                let after = tail.column + width(of: tail)
                if after < columns, lookup(column: after, row: tail.row) == link { continue }
                for join in line.hardJoins where join > start && join <= end {
                    guard lookup(line.cells[join - 1]) == link, lookup(line.cells[join]) == link else {
                        continue candidates
                    }
                }
                return spans(of: line.cells[start...end])
            }
            return nil
        }

        /// The cells SwiftTerm answers with `link` around the cell at `column`, `row`, found by
        /// asking about each: along the row while the answer stays the same, then on across each
        /// row end SwiftTerm joins, a soft wrap or an editor's hard wrap, while the link has
        /// characters left. As SwiftTerm joins two rows, the upper one's text runs to its last
        /// written cell and the lower one's starts at its first cell that is neither empty nor
        /// blank, so a crossing goes between those two cells.
        private func walked(_ link: String, column: Int, row: Int) -> [Span] {
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
            return spans
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

        /// Whether SwiftTerm's buffer has `row` continue the row above by a soft wrap.
        private func isSoftWrapped(_ row: Int) -> Bool {
            row > 0 && row < rows.count && terminal.getLine(row: row)?.isWrapped == true
        }

        // MARK: The rows' text

        /// A cell of the screen.
        private struct Cell {
            let row: Int
            let column: Int
        }

        /// Rows joined into one line, as SwiftTerm reads them into the text it matches links in:
        /// each character, with the cell it is in.
        private struct Line {
            var characters: [Character] = []
            var cells: [Cell] = []
            /// The offset of the first character of each row that only an editor's hard wrap
            /// joins to the row above.
            var hardJoins: [Int] = []
        }

        /// The line SwiftTerm reads the cell at `column`, `row` into, as far either side of the
        /// cell as a link `length` characters long could run, and the offset of the cell's
        /// character in it. nil when the cell holds none.
        ///
        /// A row that a soft wrap joins, or that one joins to the next, is read with the rest of
        /// its soft wraps and nothing else. Any other row is read with the rows SwiftTerm's
        /// heuristic for an editor's hard wrap could join it to (`mayHardJoin(above:)`), each
        /// starting at its text. The heuristic asks more of the characters either side of a row
        /// end than this does, so the line may join rows SwiftTerm does not: `located` asks
        /// SwiftTerm about each hard wrap a link crosses.
        private func line(around column: Int, row: Int, length: Int) -> (line: Line, offset: Int)? {
            let softly = isSoftWrapped(row) || isSoftWrapped(row + 1)
            func joinsAbove(_ lower: Int) -> Bool {
                guard lower > 0, lower < rows.count else { return false }
                return softly ? isSoftWrapped(lower) : !isSoftWrapped(lower) && mayHardJoin(above: lower)
            }
            func part(ofRow row: Int) -> [(character: Character, cell: Cell)] {
                characters(ofRow: row, from: (!softly && joinsAbove(row)) ? (textStart(ofRow: row) ?? 0) : 0)
            }
            let hovered = part(ofRow: row)
            guard let index = hovered.lastIndex(where: { $0.cell.column <= column }) else { return nil }
            var parts = [hovered]
            var offset = index
            var top = row
            while offset < length - 1, joinsAbove(top) {
                top -= 1
                let above = part(ofRow: top)
                parts.insert(above, at: 0)
                offset += above.count
            }
            var after = hovered.count - index - 1
            var bottom = row
            while after < length - 1, joinsAbove(bottom + 1) {
                bottom += 1
                let below = part(ofRow: bottom)
                parts.append(below)
                after += below.count
            }
            var joined = Line()
            for (position, piece) in parts.enumerated() {
                if position > 0, !softly { joined.hardJoins.append(joined.characters.count) }
                joined.characters += piece.map { $0.character }
                joined.cells += piece.map { $0.cell }
            }
            return (joined, offset)
        }

        /// Whether SwiftTerm's heuristic for an editor's hard wrap could join row `lower` to the
        /// row above: the upper row's text reaches its last fifth (its last two columns, on a grid
        /// narrower than ten), and the lower row has text.
        private func mayHardJoin(above lower: Int) -> Bool {
            guard textStart(ofRow: lower) != nil,
                  let last = cells[lower - 1].lastIndex(where: { $0 != "\0" && !$0.isWhitespace }) else { return false }
            return last >= columns - max(2, columns / 5)
        }

        /// The characters of `row` from column `start` to its last written cell, as SwiftTerm
        /// reads them into a line: an empty cell as a space, but the second half of a wide
        /// character as nothing.
        private func characters(ofRow row: Int, from start: Int) -> [(character: Character, cell: Cell)] {
            let text = cells[row]
            var characters: [(character: Character, cell: Cell)] = []
            for column in start..<max(start, textEnd(ofRow: row) ?? 0) {
                var character = text[column]
                if character == "\0" {
                    if column > 0, !text[column - 1].isASCII { continue }
                    character = " "
                }
                characters.append((character: character, cell: Cell(row: row, column: column)))
            }
            return characters
        }

        /// How many columns the character in `cell` takes: two for one whose second half is the
        /// next cell.
        private func width(of cell: Cell) -> Int {
            let row = cells[cell.row]
            guard cell.column + 1 < row.count, !row[cell.column].isASCII, row[cell.column + 1] == "\0" else { return 1 }
            return 2
        }

        /// `cells` as spans, one per row, each from its row's first cell to past its last
        /// character's second half.
        private func spans(of cells: ArraySlice<Cell>) -> [Span] {
            var spans: [Span] = []
            for cell in cells {
                let end = cell.column + width(of: cell)
                if let last = spans.last, last.row == cell.row {
                    spans[spans.endIndex - 1].columns = last.columns.lowerBound..<end
                } else {
                    spans.append(Span(row: cell.row, columns: cell.column..<end))
                }
            }
            return spans
        }

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
