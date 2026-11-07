import Foundation
import SwiftTerm
import Testing
@testable import TBDTerminalSerialization

/// Snapshots of screens that end in blank rows, round-tripped through the
/// `Pair` fixture from `TerminalSnapshotRoundTripTests`.
///
/// The oracle is the screen a person sees: the receiver's viewport row by row,
/// its history and its cursor must all match the source's. A blank row only
/// shows when something is wrong around it, so every test here compares whole
/// screens rather than the rows it set up.
@Suite("Terminal snapshot blank rows")
struct TerminalSnapshotBlankRowTests {

    // MARK: - Helpers

    /// `count` numbered lines, each ending in a line feed, so the cursor ends
    /// on a blank row below the last of them.
    private static func numberedLines(_ count: Int) -> String {
        (1...count).map { "line \($0)\r\n" }.joined()
    }

    /// One row as a person reads it. A cell nobody wrote holds NUL, and the
    /// receiver holds a space where the snapshot sent one, so both read as a
    /// space and trailing ones are dropped.
    private static func text(_ line: BufferLine?) -> String {
        var text = (line?.translateToString(trimRight: true) ?? "")
            .replacingOccurrences(of: "\u{0}", with: " ")
        while text.last == " " { text.removeLast() }
        return text
    }

    /// Every viewport row, none dropped.
    private static func viewport(of terminal: Terminal) -> [String] {
        (0..<terminal.rows).map { text(terminal.getLine(row: $0)) }
    }

    /// Every row above the viewport, oldest first.
    private static func history(of terminal: Terminal) -> [String] {
        var all: [String] = []
        var row = terminal.buffer.totalLinesTrimmed
        while let line = terminal.getScrollInvariantLine(row: row) {
            all.append(text(line))
            row += 1
        }
        return Array(all.dropLast(terminal.rows))
    }

    /// The shared oracle. `historyLimit` is the snapshot's scrollback cap,
    /// when it is below what the source holds: the receiver then holds the
    /// source's newest rows up to that many.
    private static func expectSameScreen(
        _ pair: Pair, historyLimit: Int? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(viewport(of: pair.fresh) == viewport(of: pair.source),
                "the viewport differs row by row", sourceLocation: sourceLocation)
        let sourceHistory = history(of: pair.source)
        let expectedHistory = historyLimit.map { Array(sourceHistory.suffix($0)) } ?? sourceHistory
        #expect(history(of: pair.fresh) == expectedHistory,
                "the history differs", sourceLocation: sourceLocation)
        #expect(pair.fresh.buffer.x == pair.source.buffer.x,
                "the cursor column differs", sourceLocation: sourceLocation)
        #expect(pair.fresh.buffer.y == pair.source.buffer.y,
                "the cursor row differs", sourceLocation: sourceLocation)
    }

    // MARK: - Trailing blank rows

    @Test("A screen cleared after scrollback keeps its rows and history in place")
    func screenClearedAfterScrollback() {
        let pair = Pair(cols: 80, rows: 24)
        // `ESC[H ESC[2J` is `clear` in xterm's terminfo entry. It erases the
        // screen and keeps the scrollback, so the viewport is one line of
        // text over 23 blank rows, with history above it.
        pair.transfer(Self.numberedLines(60) + "\u{1b}[H\u{1b}[2Jhi")
        #expect(Self.history(of: pair.source).count == 37, "the fixture must hold history")
        Self.expectSameScreen(pair)
        #expect(Self.viewport(of: pair.fresh).first == "hi")
    }

    @Test("Lines that each end in a line feed keep the blank row the cursor sits on")
    func linesEndingInLineFeeds() {
        let pair = Pair(cols: 80, rows: 24)
        // Thirty lines on 24 rows: seven scroll into history and the cursor
        // sits on the blank last row, below `line 30`.
        pair.transfer(Self.numberedLines(30))
        Self.expectSameScreen(pair)

        // What the shift costs a person: the next output must land on the
        // blank row, not on top of `line 30`.
        pair.source.feed(text: "$ ")
        pair.fresh.feed(text: "$ ")
        #expect(Self.text(pair.fresh.getLine(row: 23)) == "$")
        #expect(Self.text(pair.fresh.getLine(row: 22)) == "line 30")
    }

    @Test("A capped walk keeps the viewport in place")
    func cappedWalkKeepsTheViewportInPlace() {
        let pair = Pair(cols: 80, rows: 24)
        // The cap keeps 10 of the 37 history rows. Those 10 must still arrive
        // above a viewport that ends in 23 blank rows.
        pair.transfer(
            Self.numberedLines(60) + "\u{1b}[H\u{1b}[2Jhi", maxScrollbackLines: 10)
        Self.expectSameScreen(pair, historyLimit: 10)
        #expect(Self.history(of: pair.fresh).count == 10)
    }

    /// The case the trim exists for, and the control for the three above: it
    /// passes with or without the history rule. With no history the
    /// receiver never scrolls, so the walk may drop the blank rows below the
    /// text, and it still should. A fix that stopped trimming altogether
    /// would send 24 lines here, and this catches it.
    @Test("A screen without history still trims its blank rows and round-trips")
    func screenWithoutHistoryStillTrims() {
        let pair = Pair(cols: 80, rows: 24)
        // The cursor is parked below the text, among the rows the trim drops,
        // so only the closing cursor address can put it back.
        pair.transfer("one\r\ntwo\r\nthree\u{1b}[10;5H")
        Self.expectSameScreen(pair)
        #expect(Self.history(of: pair.fresh).isEmpty)

        let walk = TerminalCellWalk.styledHistory(of: pair.source, maxScrollbackLines: 500)
        #expect(walk.components(separatedBy: "\r\n").count == 3,
                "a screen with no history walks as its text alone")
    }
}
