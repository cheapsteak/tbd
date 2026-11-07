import AppKit
import Foundation
import SwiftTerm
// Scoped, not a whole-module import: `TBDShared.Terminal` is the DB row model,
// and every bare `Terminal` in this file means SwiftTerm's emulator.
import struct TBDShared.SidecarScreenRequest
import Testing
@testable import TBDApp
@testable import TBDTerminalSerialization
import TestSupport

/// Snapshots of screens that end in blank rows or hold blank cells with a
/// background colour, round-tripped through the `SnapshotPair` fixture from
/// `TerminalSnapshotRoundTripTests`.
///
/// The oracle is the screen a person sees: the receiver's viewport row by row,
/// its history and its cursor must all match the source's, and where colour
/// is the point, so must every cell's attribute. A blank row only shows when
/// something is wrong around it, so every test here compares whole screens
/// rather than the rows it set up.
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
        _ pair: SnapshotPair, historyLimit: Int? = nil,
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

    /// Every viewport cell's attribute, row by row.
    private static func attributes(of terminal: Terminal) -> [[Attribute?]] {
        (0..<terminal.rows).map { row in
            (0..<terminal.cols).map { terminal.getCharData(col: $0, row: row)?.attribute }
        }
    }

    /// How many cells hold a different attribute in one grid than the other.
    private static func differingCells(_ a: [[Attribute?]], _ b: [[Attribute?]]) -> Int {
        zip(a, b).reduce(0) { count, rows in
            count + zip(rows.0, rows.1).filter { cells in cells.0 != cells.1 }.count
        }
    }

    /// How many cells have a background other than the default, so a test
    /// can show its fixture made the cells it is about.
    private static func colouredCells(_ grid: [[Attribute?]]) -> Int {
        grid.joined().compactMap { $0 }.filter { $0.bg != .defaultColor }.count
    }

    // MARK: - Trailing blank rows

    @Test("A screen cleared after scrollback keeps its rows and history in place")
    func screenClearedAfterScrollback() {
        let pair = SnapshotPair(cols: 80, rows: 24)
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
        let pair = SnapshotPair(cols: 80, rows: 24)
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
        let pair = SnapshotPair(cols: 80, rows: 24)
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
        let pair = SnapshotPair(cols: 80, rows: 24)
        // The cursor is parked below the text, among the rows the trim drops,
        // so only the closing cursor address can put it back.
        pair.transfer("one\r\ntwo\r\nthree\u{1b}[10;5H")
        Self.expectSameScreen(pair)
        #expect(Self.history(of: pair.fresh).isEmpty)

        let walk = TerminalCellWalk.styledHistory(of: pair.source, maxScrollbackLines: 500)
        #expect(walk.components(separatedBy: "\r\n").count == 3,
                "a screen with no history walks as its text alone")
    }

    @Test("An erased wrapped row still moves the receiver down a row, and stays wrapped")
    func erasedWrappedRowKeepsItsPlace() {
        let pair = SnapshotPair(cols: 80, rows: 24)
        // A hundred `a`s wrap onto the last row, which `ESC[2K` then erases.
        // EL leaves the row's wrap flag set, so the source holds a
        // continuation with nothing in it, the cursor on it, and 8 rows of
        // history above the viewport.
        pair.transfer(
            Self.numberedLines(30) + String(repeating: "a", count: 100) + "\r\u{1b}[2K")
        #expect(Self.history(of: pair.source).count == 8, "the fixture must scroll 8 rows")
        Self.expectSameScreen(pair)
        #expect(Self.text(pair.fresh.getLine(row: 22)) == String(repeating: "a", count: 80))

        // The row arrives as the continuation it is, with no character in it.
        #expect(pair.fresh.getLine(row: 23)?.isWrapped == true)
        #expect(pair.fresh.getLine(row: 23)?.getTrimmedLength() == 0)
    }

    // MARK: - Captures

    @Test("A capture drops the blank rows below a cleared screen's text, and a replay keeps them")
    func captureDropsTrailingBlankRows() {
        let pair = SnapshotPair(cols: 80, rows: 24)
        pair.source.feed(
            text: Self.numberedLines(60) + "\u{1b}[H\u{1b}[2J$ ls\r\na  b  c\r\n$ ")

        // 37 rows of history and three of text, with nothing after the prompt:
        // a revive prints this, so a blank row here pushes its prompt down.
        let capture = TerminalCellWalk.styledCapture(of: pair.source, maxScrollbackLines: 500)
        #expect(capture.components(separatedBy: "\r\n").count == 40)
        #expect(capture.hasSuffix("$ \u{1b}[0m"))

        // A replay of the same screen keeps all 61 rows, because the receiver's
        // scroll depends on them.
        let replay = TerminalCellWalk.styledHistory(of: pair.source, maxScrollbackLines: 500)
        #expect(replay.components(separatedBy: "\r\n").count == 61)
    }

    // MARK: - Blank cells with a background colour

    @Test("Erasing under a background colour keeps the colour", arguments: [
        // EL, EL 2 and ED under three colours. Rows 0 and 1 are coloured to
        // the last column, so each ends in pending wrap ahead of its line
        // ending. Row 2 is coloured from column 4 and every row below it in
        // full, so the screen's last row holds nothing but coloured blanks.
        "\u{1b}[41m\u{1b}[K\u{1b}[2;1H\u{1b}[42m\u{1b}[2K\u{1b}[3;5H\u{1b}[43m\u{1b}[J\u{1b}[0m",
        // ECH in the middle of a row: coloured blanks with plain ones after
        // them, so the last cell of the row says nothing about the rest.
        "ab\u{1b}[45m\u{1b}[3X\u{1b}[0m",
        // DCH fills the end of the row it shifts left under the background,
        // past a run of plain blanks.
        "abcdefgh\u{1b}[1;3H\u{1b}[45m\u{1b}[2P\u{1b}[0m",
    ])
    func eraseUnderABackgroundKeepsTheColour(input: String) {
        let pair = SnapshotPair(cols: 80, rows: 24)
        pair.source.feed(text: input)
        let expected = Self.attributes(of: pair.source)
        #expect(Self.colouredCells(expected) > 0, "the fixture must leave coloured blanks")

        pair.transfer("")
        #expect(Self.differingCells(Self.attributes(of: pair.fresh), expected) == 0)
        Self.expectSameScreen(pair)
        #expect(Self.history(of: pair.fresh).isEmpty,
                "a row coloured to its last column wrapped an extra row")
    }

    @Test("A coloured alternate screen keeps its colour on the receiver and the source")
    func colouredAlternateScreen() {
        let pair = SnapshotPair(cols: 80, rows: 24)
        pair.source.feed(text: "\u{1b}[?1049h\u{1b}[44m\u{1b}[2Jx\u{1b}[0m")
        let expected = Self.attributes(of: pair.source)
        #expect(Self.colouredCells(expected) == 80 * 24, "the fixture must colour every cell")

        pair.transfer("")
        #expect(pair.fresh.isCurrentBufferAlternate)
        #expect(Self.differingCells(Self.attributes(of: pair.fresh), expected) == 0)
        // The snapshot leaves the source's alt screen to walk the primary and
        // repaints it from the same rendering it sends, so the source loses
        // whatever the receiver loses. Compare it with what it held before.
        #expect(pair.source.isCurrentBufferAlternate)
        #expect(Self.differingCells(Self.attributes(of: pair.source), expected) == 0,
                "the snapshot changed the source's own alt screen")
        Self.expectSameScreen(pair)
    }

    @Test("A coloured last row under history arrives whole, with no extra row after it")
    func colouredLastRowUnderHistory() {
        let pair = SnapshotPair(cols: 20, rows: 5)
        // Ten lines scroll six into history and leave the cursor on the last
        // row, which `ESC[2K` then colours out to the last column. That row
        // is the last one the walk sends, so the receiver ends it in pending
        // wrap with only mode escapes and the cursor address to follow.
        pair.source.feed(text: Self.numberedLines(10) + "\u{1b}[44m\u{1b}[2K\u{1b}[0m")
        let expected = Self.attributes(of: pair.source)
        #expect(Self.colouredCells(expected) == 20, "the fixture must colour the last row")

        pair.transfer("")
        #expect(Self.differingCells(Self.attributes(of: pair.fresh), expected) == 0)
        Self.expectSameScreen(pair)
        #expect(Self.history(of: pair.fresh).count == 6)
    }

    @Test("Coloured blanks past the last column do not stretch the row they sit in")
    func colouredBlanksPastTheLastColumn() {
        let pair = SnapshotPair(cols: 80, rows: 24)
        // The alternate screen has no scrollback, so narrowing the terminal
        // does not reflow it and its rows keep their old width. Row 0 holds
        // an `x`, then coloured blanks from column 74, which the 70-column
        // screen leaves past its last column.
        pair.source.feed(text: "\u{1b}[?1049hx\u{1b}[1;75H\u{1b}[44m\u{1b}[K\u{1b}[0m")
        pair.source.resize(cols: 70, rows: 24)
        pair.fresh.resize(cols: 70, rows: 24)
        #expect(pair.source.getLine(row: 0)?.count == 80,
                "the fixture must leave a row wider than the screen")
        #expect(pair.source.getLine(row: 0)?.getTrimmedLength() == 1)

        // Read before the transfer, which repaints the source's alt screen
        // from what it sends. With its SGR runs taken out, the row is the `x`
        // alone: no blanks out to the edge, and no cursor moves either.
        let firstRow = TerminalCellWalk.styledViewport(of: pair.source)
            .components(separatedBy: "\r\n").first ?? ""
        let sgr = "\u{1b}\\[[0-9;:]*m"
        #expect(firstRow.replacingOccurrences(of: sgr, with: "", options: .regularExpression) == "x")

        pair.transfer("")
        #expect(pair.fresh.getLine(row: 0)?.getTrimmedLength() == 1,
                "the receiver's row runs past its `x`")
    }
}

/// The viewer's half of the Closed Terminals capture, through the production
/// path a `screenRequest` takes. The daemon's half calls the same capture walk
/// (`HolderReader.closedTerminalCapture`), which this target cannot import.
@Suite("Closed-terminal capture of a cleared screen")
@MainActor
struct TerminalCaptureBlankRowTests {
    @Test("A viewer's capture of a cleared screen ends at the prompt")
    func viewerCaptureEndsAtThePrompt() throws {
        // Isolated defaults, per `Tests/CLAUDE.md`, as `ViewerScreenProducerTests` does.
        let suite = TestDefaultsSuite("TBDAppTests.CaptureBlankRows")
        defer { suite.tearDown() }
        let view = TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 300),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: suite.defaults))
        // Enough lines to scroll whatever grid this frame gives, then `clear`
        // and a short exchange, which leaves blank rows below the prompt.
        let input = (1...200).map { "line \($0)\r\n" }.joined()
            + "\u{1b}[H\u{1b}[2J$ ls\r\na  b  c\r\n$ "
        view.withTerminal { $0.feed(text: input) }

        let request = SidecarScreenRequest(
            terminalID: UUID(), requestID: UUID(), requestedLines: 50,
            retainedScrollbackLines: 5_000, wantStyledCapture: true)
        let now = ContinuousClock.now
        let answer = ViewerScreenProducer.answer(
            for: request, terminalView: view, lastByteAt: nil, attachedAt: now, now: now)
        let capture = try #require(answer.styledCapture)

        // The shape ends in one `\n`, so the last component is empty and the
        // one before it is the capture's last line, which must be the prompt.
        let lines = capture.components(separatedBy: "\n")
        #expect(lines.last == "")
        #expect(lines.dropLast().last?.contains("$ ") == true,
                "the capture ends in blank rows, which a revive prints above its prompt")
    }
}
