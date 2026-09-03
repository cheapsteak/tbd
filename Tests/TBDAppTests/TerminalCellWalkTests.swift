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

        let fresh = replay(history, cols: 10, rows: 5)
        #expect(fresh.row(0) == String(repeating: "a", count: 10))
        #expect(fresh.row(2) == String(repeating: "a", count: 5))
    }

    @Test("The viewport-only walk excludes scrollback")
    func viewportOnly() {
        let source = Harness(rows: 5)
        for i in 1...40 { source.feed("line-\(i)\r\n") }
        #expect(lineCount(TerminalCellWalk.styledViewport(of: source.terminal)) == 5)
    }
}
