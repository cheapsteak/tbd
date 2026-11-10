// The text under a ⌘-click, read at the press for a host that opens what plain text names.
//
// The view finds no paths or URLs in it itself. Which text names a file, and what a URL may open,
// are the host's rules, and TBD's host already has them, written against SwiftTerm's rows; so the
// rows are handed over in the shape SwiftTerm gives them.

/// The screen under a left ⌘-press that landed on no OSC 8 link: the rows on view and the cell
/// pressed, read under the terminal's lock at the press, so a feed between the press and its
/// release cannot change what the press opens.
public struct GhosttyClickedText: Sendable, Equatable {
    /// One row of the viewport.
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

    /// The viewport's rows, top to bottom.
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
    /// The viewport of `state` with the cell at `column`, `row` pressed. Inside the lock.
    init(viewportOf state: GhosttyTerminalState, column: Int, row: Int) {
        let rows = (0..<state.rows).map { index -> Row in
            guard let gridRow = state.gridRow(.viewport, index) else {
                return Row(text: "", isWrapContinuation: false)
            }
            var text = ""
            text.reserveCapacity(gridRow.cells.count)
            // The first character only: a cell holds one, and a matcher counts one per column.
            for cell in gridRow.cells { text.append(cell.text.first ?? "\0") }
            return Row(text: text, isWrapContinuation: gridRow.isWrapContinuation)
        }
        self.init(rows: rows, column: column, row: row, columns: state.cols)
    }
}

/// What a left ⌘-press lands on.
enum CommandClickTarget: Sendable, Equatable {
    /// An OSC 8 link: its URI.
    case link(String)
    /// No link: the text around the press, for the host to look in.
    case text(GhosttyClickedText)
}
