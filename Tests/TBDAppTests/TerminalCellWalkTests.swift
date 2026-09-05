import Foundation
import SwiftTerm
import Testing
@testable import TBDTerminalSerialization

private final class SilentDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

private struct Harness {
    let delegate = SilentDelegate()
    let terminal: Terminal
    init(cols: Int = 80, rows: Int = 25, scrollback: Int = 500) {
        terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
    }
    func feed(_ text: String) { terminal.feed(text: text) }
    func row(_ r: Int) -> String {
        // `skipNullCellsFollowingWide` must be explicit: the default renders
        // every column, including the NUL placeholder a wide character's
        // second cell holds, which would embed a stray `\0` after every CJK
        // or emoji glyph in what should be a plain rendered row.
        terminal.getLine(row: r)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true) ?? ""
    }
}

/// Replays a walk's output into a fresh terminal, verbatim — the writer feeds
/// it exactly as produced, so a test that re-joined it would be testing
/// something the production path never does.
private func replay(_ text: String, cols: Int = 80, rows: Int = 25) -> Harness {
    let fresh = Harness(cols: cols, rows: rows)
    fresh.feed(text)
    return fresh
}

private func lineCount(_ text: String) -> Int {
    text.components(separatedBy: "\r\n").count
}

/// Strips `ESC[...m` SGR runs, leaving only the characters a receiving
/// terminal would actually place into its grid. Used to pin the walk's
/// per-cell character choices directly, independent of styling.
private func visibleCharacters(_ text: String) -> String {
    var out = ""
    var chars = Substring(text)
    while let char = chars.first {
        if char == "\u{1b}" {
            chars = chars.drop { $0 != "m" }
            if !chars.isEmpty { chars.removeFirst() }
            continue
        }
        out.append(char)
        chars.removeFirst()
    }
    return out
}

@Suite("Terminal cell walk")
struct TerminalCellWalkTests {
    @Test("Plain text survives a round trip")
    func plainText() {
        let source = Harness()
        source.feed("hello\r\nworld")
        let history = TerminalCellWalk.styledHistory(of: source.terminal, maxScrollbackLines: 100)
        let fresh = replay(history)
        #expect(fresh.row(0) == "hello")
        #expect(fresh.row(1) == "world")
    }

    @Test("Colour and bold survive a round trip, cell for cell")
    func styledText() {
        let source = Harness()
        source.feed("\u{1b}[1;31mRED\u{1b}[0m plain")
        let history = TerminalCellWalk.styledHistory(of: source.terminal, maxScrollbackLines: 100)
        let fresh = replay(history)
        for col in 0..<11 {
            let a = source.terminal.getCharData(col: col, row: 0)
            let b = fresh.terminal.getCharData(col: col, row: 0)
            #expect(a?.attribute == b?.attribute, "attribute differs at column \(col)")
            #expect(a?.getCharacter() == b?.getCharacter(), "character differs at column \(col)")
        }
    }

    @Test("Scrollback above the viewport is included and bounded")
    func scrollbackIncluded() {
        let source = Harness(rows: 5)
        for i in 1...40 { source.feed("line-\(i)\r\n") }
        let all = TerminalCellWalk.styledHistory(of: source.terminal, maxScrollbackLines: 1000)
        #expect(lineCount(all) > 5, "expected scrollback beyond the 5-row viewport")
        let capped = TerminalCellWalk.styledHistory(of: source.terminal, maxScrollbackLines: 10)
        #expect(lineCount(capped) <= 10 + 5, "cap must bound the scrollback half")
        #expect(capped.contains("line-40"), "the cap must keep the TAIL")
        #expect(!capped.contains("line-1\r"), "the cap must drop the HEAD")
    }

    @Test("A wide character is not doubled by its spacer cell")
    func wideCharacter() {
        let source = Harness()
        source.feed("日本語")
        let history = TerminalCellWalk.styledHistory(of: source.terminal, maxScrollbackLines: 10)
        #expect(replay(history).row(0) == "日本語")
    }

    @Test("A soft-wrapped line carries no line ending, so the receiver re-wraps it")
    func wrappedLine() {
        let source = Harness(cols: 10, rows: 5)
        source.feed(String(repeating: "a", count: 25))
        let history = TerminalCellWalk.styledHistory(of: source.terminal, maxScrollbackLines: 50)

        // The discriminating assertion. A walk that joined every line with
        // \r\n would produce three separated lines here and still put the
        // right text on screen — so checking the rendered rows alone cannot
        // tell a soft wrap from a hard break. Count the separators instead:
        // 25 columns across a 10-column terminal is ONE logical line.
        #expect(lineCount(history) == 1, "wrapped continuations must not be separated")

        // Belt-and-suspenders: blank cells must never reach the wire as a
        // literal NUL (see `blankCellIsSpace` below for the assertion that
        // actually discriminates this — in THIS fixture the trailing-blank
        // trim already removes rows 3 and 4, so a correct lookahead never
        // reaches a blank cell here at all and this check alone cannot tell
        // the fix from its absence).
        #expect(!history.unicodeScalars.contains { $0.value == 0 }, "blank cells must not be emitted as NUL")

        // The discriminating assertion for the lookahead fix itself. Under
        // `fullWidth = line.isWrapped` (the brief's original, wrong,
        // self-referential check), the wrap's last physical row (row 2, only
        // 5 columns of real content) gets forced to full width and padded
        // with 5 extra blank cells — which the NUL fix above turns into 5
        // extra spaces rather than 5 NULs, so a rendered-row comparison
        // alone stays green under that mutation. Stripping SGR and joins
        // down to the raw characters catches it: the padding survives as
        // trailing spaces the source terminal never had.
        #expect(
            visibleCharacters(history) == String(repeating: "a", count: 25),
            "the wrap's last physical row must be trimmed, not padded to full width")

        let fresh = replay(history, cols: 10, rows: 5)
        #expect(fresh.row(0) == String(repeating: "a", count: 10))
        #expect(fresh.row(2) == String(repeating: "a", count: 5))
    }

    @Test("A blank cell inside a row renders as a space, not a raw NUL")
    func blankCellIsSpace() {
        let source = Harness()
        // Move the cursor forward 11 columns without writing anything, then
        // write "hello" — the untouched prefix cells carry code 0 (never
        // written), the same shape `getTrimmedLength()` includes whenever a
        // row's last write is not its first: cursor positioning, a
        // multi-column erase, anything that leaves a gap before real content.
        source.feed("\u{1b}[11Chello")
        let history = TerminalCellWalk.styledHistory(of: source.terminal, maxScrollbackLines: 10)

        // A raw NUL hits the receiving parser's ground-state dispatch with no
        // case for 0x00 — it is logged as an unknown code and the column does
        // not advance, so the gap collapses instead of holding position.
        #expect(!history.unicodeScalars.contains { $0.value == 0 }, "blank cells must not be emitted as NUL")

        // The direct consequence if they were: "hello" would land at column 0
        // instead of column 11, because the collapsed gap consumed no columns
        // on the receiver.
        let fresh = replay(history)
        #expect(fresh.row(0) == String(repeating: " ", count: 11) + "hello")
    }

    @Test("The viewport-only walk excludes scrollback")
    func viewportOnly() {
        let source = Harness(rows: 5)
        for i in 1...40 { source.feed("line-\(i)\r\n") }
        #expect(lineCount(TerminalCellWalk.styledViewport(of: source.terminal)) == 5)
    }
}
