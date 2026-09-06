import Darwin
import Foundation
import Testing

@testable import TBDDaemonLib

/// What `terminal.output` owes its readers: **text, with no invisible holes in
/// it.**
///
/// A holder-backed session's screen is the daemon's own headless emulator, and
/// a cell that no program ever wrote holds `CharData.Null` — code 0. Rendering
/// that cell literally puts `U+0000` into the string. Nothing displays it,
/// nothing in a diff shows it, and every consumer that matches on the text —
/// fleet supervision, the hibernation pending-input rail, the interactive
/// login driver — silently fails to find the characters on either side of it.
///
/// The holes are not rare and they are not stationary. A TUI like Claude Code
/// paints differentially: instead of overwriting a run of cells with blanks it
/// *positions the cursor past them* (`\r ESC[82C ESC[1B ● high`,
/// `✻ ESC[3G Cogitated`), so every skipped cell becomes a NUL, and which cells
/// get skipped changes with each repaint — the holes appear to move.
///
/// tmux `capture-pane`, which this render replaces for machine reads, returns
/// spaces. So does the app-side serializer (`TerminalCellWalk`). This suite
/// pins the daemon's renderer to the same projection.
///
/// It exercises the production path rather than a copy of it: `ingest` feeds
/// the reader's emulator synchronously, and `renderScreen` /
/// `renderScreenWithScrollback` are the very functions `terminal.output`
/// calls. No drain thread and no real pty are involved, so nothing here is
/// timing-dependent.
@Suite struct HolderRenderProjectionTests {

    private static let nul = "\u{0}"
    private static let esc = "\u{1b}"

    // MARK: - Positioned writes leave spaces, not NULs

    /// The signature that started this: a spinner glyph, a jump to column 3,
    /// and a word. The cell between them was never written.
    @Test("a cursor jump on the current row renders as a space")
    func aColumnJumpRendersAsASpace() async throws {
        let harness = try Harness(columns: 40, rows: 8)
        defer { harness.tearDown() }

        await harness.reader.ingest(preamble: Self.data("✻\(Self.esc)[3GCogitated"))
        let screen = await harness.reader.renderScreen()

        #expect(screen.components(separatedBy: "\n").first == "✻ Cogitated")
        #expect(
            !screen.contains(Self.nul),
            "the rendered screen carries U+0000: \(screen.debugDescription)")
    }

    /// Cursor-forward from the start of a row. Five columns nobody wrote.
    @Test("cursor-forward leaves spaces across the columns it skipped")
    func cursorForwardLeavesSpaces() async throws {
        let harness = try Harness(columns: 40, rows: 8)
        defer { harness.tearDown() }

        await harness.reader.ingest(preamble: Self.data("\r\(Self.esc)[5Cx"))
        let screen = await harness.reader.renderScreen()

        #expect(screen == "     x", "rendered \(screen.debugDescription)")
    }

    /// An absolute position onto a lower row. The rows above it were never
    /// touched at all, and must stay *empty* — the trailing-blank trim runs off
    /// `getTrimmedLength()`, which is computed before the projection, so
    /// turning never-written cells into spaces must not pad blank rows out to
    /// the full width.
    @Test("a positioned write pads its own row and leaves the rows above empty")
    func aPositionedWriteLeavesBlankRowsBlank() async throws {
        let harness = try Harness(columns: 40, rows: 8)
        defer { harness.tearDown() }

        await harness.reader.ingest(preamble: Self.data("\(Self.esc)[3;10Hhello"))
        let screen = await harness.reader.renderScreen()

        let rows = screen.components(separatedBy: "\n")
        #expect(rows.count == 3, "rendered \(screen.debugDescription)")
        #expect(rows.first == "")
        #expect(rows.dropFirst().first == "")
        #expect(rows.last == "         hello", "rendered \(rows.last.debugDescription)")
        #expect(!screen.contains(Self.nul))
    }

    // MARK: - Wide glyphs

    /// The trailing half of a two-cell glyph carries code 0 as well, and it is
    /// *not* an unwritten cell: projecting it as a space would double the width
    /// of every CJK character and every emoji.
    @Test("a wide glyph is not padded with a stray space")
    func wideGlyphsAreNotDoubled() async throws {
        let harness = try Harness(columns: 40, rows: 8)
        defer { harness.tearDown() }

        await harness.reader.ingest(preamble: Self.data("日本 x"))
        let screen = await harness.reader.renderScreen()

        #expect(screen == "日本 x", "rendered \(screen.debugDescription)")
        #expect(!screen.contains(Self.nul))
    }

    /// Wide glyphs and a positioned write on the row below, to show the two
    /// projections do not interfere: the gap after `a` is three spaces because
    /// `ESC[4G` is column 4, and the wide row above is still two glyphs wide.
    @Test("columns still line up on the row after a wide-glyph run")
    func columnsLineUpBelowAWideGlyphRun() async throws {
        let harness = try Harness(columns: 40, rows: 8)
        defer { harness.tearDown() }

        await harness.reader.ingest(preamble: Self.data("日本\r\na\(Self.esc)[4Gb"))
        let screen = await harness.reader.renderScreen()

        #expect(screen == "日本\na  b", "rendered \(screen.debugDescription)")
        #expect(!screen.contains(Self.nul))
    }

    // MARK: - The scrollback render

    /// `renderScreenWithScrollback` is a second, separate walk over the buffer
    /// and needs the projection in its own right. The gap here is deliberately
    /// placed on a line that has already scrolled off the viewport, so only the
    /// scrollback path can produce it.
    @Test("the scrollback render projects never-written cells as spaces too")
    func scrollbackRenderProjectsNeverWrittenCells() async throws {
        let harness = try Harness(columns: 40, rows: 5)
        defer { harness.tearDown() }

        var stream = ""
        for index in 0..<8 {
            if index == 1 {
                stream += "\(Self.esc)[10Cgap\r\n"
            } else {
                stream += "row \(index)\r\n"
            }
        }
        await harness.reader.ingest(preamble: Self.data(stream))

        let viewport = await harness.reader.renderScreen()
        #expect(
            !viewport.contains("gap"),
            "the gap line is still on screen, so this asserts nothing about scrollback")

        let history = await harness.reader.renderScreenWithScrollback(maxLines: 100)
        #expect(
            history.contains("          gap"),
            "rendered \(history.debugDescription)")
        #expect(
            !history.contains(Self.nul),
            "the rendered scrollback carries U+0000: \(history.debugDescription)")
    }

    // MARK: - Harness

    private static func data(_ text: String) -> Data { Data(text.utf8) }

    /// A `HolderReader` over one end of a socketpair, never started.
    ///
    /// Nothing on this path reads a tty's ioctls, and starting the drain would
    /// only add a thread and a wait to a test whose whole subject is what the
    /// emulator renders. `ingest` feeds the same emulator the drain loop feeds,
    /// on the calling thread.
    private struct Harness {
        let reader: HolderReader
        private let ours: Int32

        init(columns: Int, rows: Int) throws {
            var pair: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
            ours = pair[1]
            // The reader owns `pair[0]` and closes it in `tearDown`.
            reader = HolderReader(
                sessionID: UUID(),
                ptyFD: pair[0],
                columns: columns,
                rows: rows,
                scrollbackLines: 200)
        }

        /// Closes this side only. The reader's own end is closed by its
        /// `deinit`, which is safe precisely because the reader is `.idle`:
        /// no thread was ever started, so none can be inside a read on it.
        func tearDown() {
            close(ours)
        }
    }
}
