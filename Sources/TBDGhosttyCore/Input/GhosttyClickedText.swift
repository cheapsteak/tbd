// The text under a ⌘-click, read at the press for a host that opens what plain text names.
//
// The view finds no paths or URLs in it itself. Which text names a file, and what a URL may open,
// are the host's rules, and TBD's host already has them, written against SwiftTerm's rows; so the
// rows are handed over in the shape SwiftTerm gives them.

/// The screen under a left ⌘-press that landed on no OSC 8 link: the rows on view, the rows past
/// them that a line on view runs on into, and the cell pressed, read under the terminal's lock at
/// the press, so a feed between the press and its release cannot change what the press opens.
public struct GhosttyClickedText: Sendable, Equatable {
    /// One row of the screen.
    public struct Row: Sendable, Equatable {
        /// The row's text, one `Character` per column, as SwiftTerm's
        /// `BufferLine.translateToString()` reads a row: a cell's text, or `"\0"` for a cell with
        /// none, which is a cell never written, an erased one, or the second half of a wide
        /// character. A printed space is a space.
        public var text: String
        /// True when the row continues the one above it: a soft wrap.
        public var isWrapContinuation: Bool

        public init(text: String, isWrapContinuation: Bool) {
            self.text = text
            self.isWrapContinuation = isWrapContinuation
        }
    }

    /// The viewport's rows, top to bottom, with the rows above and below it that a line on view
    /// runs on into (`init(viewportOf:column:row:)`).
    public var rows: [Row]
    /// The pressed cell's column, zero-based.
    public var column: Int
    /// The pressed cell's row in `rows`.
    public var row: Int
    /// The grid's width in cells.
    public var columns: Int
    /// True when the press is the click that activates the view's window
    /// (`GhosttyTerminalView.acceptsActivatingClick`).
    public var activatesWindow: Bool

    public init(rows: [Row], column: Int, row: Int, columns: Int, activatesWindow: Bool = false) {
        self.rows = rows
        self.column = column
        self.row = row
        self.columns = columns
        self.activatesWindow = activatesWindow
    }
}

extension GhosttyClickedText {
    /// The most rows read past each edge of the viewport. A link that runs on further than this
    /// past an edge is cut there.
    static let reachPastViewport = 200

    /// The viewport of `state`, with the cell at `column`, `row` of it pressed. Inside the lock.
    ///
    /// SwiftTerm finds a link on every row of its line, on view or not: the rows a soft wrap joins,
    /// or, on a row no soft wrap joins, the rows its heuristic for an editor's hard wrap joins. Cut
    /// at the viewport's edge, a link running off it would open the wrong page, so past each edge
    /// rows are read on for as long as SwiftTerm could join them (`Row.mayJoin`). A row read that
    /// SwiftTerm does not join changes nothing it finds.
    init(viewportOf state: GhosttyTerminalState, column: Int, row: Int) {
        let columns = state.cols
        var rows = (0..<state.rows).map { Row(state.gridRow(.viewport, $0)) }
        var pressedRow = row
        if let top = state.viewportTopScreenRow {
            for above in stride(from: top - 1, through: max(0, top - Self.reachPastViewport), by: -1) {
                guard let upper = state.gridRow(.screen, above).map({ Row($0) }), let lower = rows.first,
                      Row.mayJoin(upper, lower, columns: columns) else { break }
                rows.insert(upper, at: 0)
                pressedRow += 1
            }
            let bottom = top + state.rows
            for below in bottom..<(bottom + Self.reachPastViewport) {
                guard let lower = state.gridRow(.screen, below).map({ Row($0) }), let upper = rows.last,
                      Row.mayJoin(upper, lower, columns: columns) else { break }
                rows.append(lower)
            }
        }
        self.init(rows: rows, column: column, row: pressedRow, columns: columns)
    }
}

extension GhosttyClickedText.Row {
    /// `gridRow` as SwiftTerm reads a row, or an empty row when it could not be read.
    package init(_ gridRow: GhosttyGridRow?) {
        guard let gridRow else {
            self.init(text: "", isWrapContinuation: false)
            return
        }
        var text = ""
        text.reserveCapacity(gridRow.cells.count)
        // The first character only: a cell holds one, and a matcher counts one per column.
        for cell in gridRow.cells { text.append(cell.text.first ?? "\0") }
        self.init(text: text, isWrapContinuation: gridRow.isWrapContinuation)
    }

    /// Whether SwiftTerm could read `upper` and the `lower` row under it as one line: `lower`
    /// continues a soft wrap, or `upper` has text at or past its middle column. SwiftTerm's
    /// hard-wrap heuristic joins two rows only when the upper one has text in its last fifth (its
    /// last two columns, on a grid narrower than ten), so this holds for every pair it joins.
    static func mayJoin(_ upper: Self, _ lower: Self, columns: Int) -> Bool {
        if lower.isWrapContinuation { return true }
        let characters = Array(upper.text)
        guard let last = characters.lastIndex(where: { $0 != "\0" && !$0.isWhitespace }) else { return false }
        return last >= (columns - 1) / 2
    }
}

/// What a left ⌘-press lands on.
package enum CommandClickTarget: Sendable, Equatable {
    /// An OSC 8 link: its URI.
    case link(String)
    /// No link: the text around the press, for the host to look in.
    case text(GhosttyClickedText)
}
