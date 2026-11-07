import TBDTerminalSerialization

/// What a coordinator may read from, or do to, a terminal's model while the
/// engine holds its lock.
///
/// A reader exists only inside `TerminalEngine.withScreen`, and only for the
/// length of that closure. Copy values out and return them; never store the
/// reader, and never call back into the engine from inside the closure. The
/// lock is not recursive, so re-entry traps, and anything stored would outlive
/// the lock that made it safe to read.
///
/// Everything a coordinator needs from one observation goes into one closure.
/// That is what makes the reads one observation: two `withScreen` calls can
/// have an IO-thread `feed` land between them, and pair, say, a mouse mode from
/// after a mode change with a screen from before it.
protocol TerminalScreenReader {
    /// Whether the program has asked for mouse reports.
    var mouseReporting: Bool { get }
    /// Whether the alternate screen is shown.
    var isAlternateScreen: Bool { get }
    /// The text of visible row `row`, counted from the top of the viewport,
    /// with trailing blanks trimmed. Nil when `row` is off the screen.
    func lineText(row: Int) -> String?
    /// The OSC 8 hyperlink of the cell at a visible grid position, or nil when
    /// the cell carries none or the position is off the screen.
    func hyperlink(column: Int, row: Int) -> String?
    /// The lines, viewport, cursor, size and child modes the daemon's screen
    /// request asks for, as `TerminalScreenProjection` shapes them.
    func projection(maxLines: Int) -> ProjectedScreen
    /// The styled capture Closed Terminals history records, as
    /// `TerminalCellWalk` shapes it.
    func styledCapture(maxScrollbackLines: Int) -> String
    /// Sends `abs(lines)` wheel reports at a grid position: up for a positive
    /// count, down for a negative one.
    ///
    /// Inside the lock on purpose. The scroll monitor reads the mouse mode and
    /// sends the reports in one hold, so a program that leaves mouse mode
    /// between the two cannot be sent reports it no longer asked for.
    func sendWheelReports(lines: Int, column: Int, row: Int)
}
