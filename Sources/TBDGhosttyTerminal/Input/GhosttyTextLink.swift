// A link the host found in plain text under a ⌘-hover, for the view to underline.
//
// The view finds no paths or URLs itself (`GhosttyClickedText`), so it asks the host which cells
// the link under the pointer covers (`GhosttyTerminalView.onCommandHoverText`) and draws the
// underline there, as it does under an OSC 8 link.

/// A link in plain text: what it names and the cells it covers, row by row. A soft wrap, or an
/// editor's hard wrap, can carry it onto the rows below.
public struct GhosttyTextLink: Sendable, Equatable {
    /// The cells a link covers on one row.
    public struct Span: Sendable, Equatable {
        /// The row: from the host, an index into the `GhosttyClickedText.rows` it was given.
        public var row: Int
        /// The columns, zero-based.
        public var columns: Range<Int>

        public init(row: Int, columns: Range<Int>) {
            self.row = row
            self.columns = columns
        }
    }

    /// What the link names: a URL or a path.
    public var text: String
    /// The cells it covers, one span per row, top row first.
    public var spans: [Span]

    public init(text: String, spans: [Span]) {
        self.text = text
        self.spans = spans
    }
}
