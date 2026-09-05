import Foundation
import SwiftTerm
import Testing
@testable import TBDTerminalSerialization

private final class ReplyCollector: TerminalDelegate, ModeReplyReader {
    var bytes: [UInt8] = []
    weak var terminal: Terminal?
    func send(source: Terminal, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
    func requestMode(_ mode: Int, decPrivate: Bool) -> Int? {
        guard let terminal else { return nil }
        bytes.removeAll()
        let prefix = decPrivate ? "?" : ""
        terminal.feed(text: "\u{1b}[\(prefix)\(mode)$p")
        let reply = String(bytes: bytes, encoding: .utf8) ?? ""
        guard let head = reply.range(of: "\(prefix)\(mode);"),
              let tail = reply[head.upperBound...].range(of: "$y") else { return nil }
        return Int(reply[head.upperBound..<tail.lowerBound])
    }
}

private final class Pair {
    let sourceReply = ReplyCollector()
    let freshReply = ReplyCollector()
    let source: Terminal
    let fresh: Terminal

    init(cols: Int = 80, rows: Int = 25) {
        let options = TerminalOptions(cols: cols, rows: rows, scrollback: 500)
        source = Terminal(delegate: sourceReply, options: options)
        fresh = Terminal(delegate: freshReply, options: options)
        sourceReply.terminal = source
        freshReply.terminal = fresh
    }

    /// Feeds the source, snapshots it, replays into the fresh terminal.
    func transfer(_ input: String, maxScrollbackLines: Int = 500) {
        source.feed(text: input)
        let data = TerminalSnapshotWriter.snapshot(
            of: source, reply: sourceReply, maxScrollbackLines: maxScrollbackLines)
        fresh.feed(byteArray: [UInt8](data))
    }

    func states() -> (CapturedTerminalState, CapturedTerminalState) {
        (TerminalModeCapture.capture(from: source, reply: sourceReply),
         TerminalModeCapture.capture(from: fresh, reply: freshReply))
    }
}

@Suite("Terminal snapshot round trip")
struct TerminalSnapshotRoundTripTests {
    @Test("Every captured mode survives the round trip")
    func stateRoundTrip() {
        let pair = Pair()
        pair.transfer("\u{1b}[?6h\u{1b}[?7l\u{1b}[?25l\u{1b}[?66h\u{1b}[4h\u{1b}[?2004h"
            + "\u{1b}[?1002h\u{1b}[?1006h\u{1b}[3;20r\u{1b}[1;31mhello")
        let (before, after) = pair.states()
        #expect(after == before)
    }

    @Test("The visible screen matches cell for cell")
    func screenRoundTrip() {
        let pair = Pair()
        pair.transfer("\u{1b}[1;32mgreen bold\u{1b}[0m\r\nplain\r\n\u{1b}[7minverse")
        for row in 0..<3 {
            for col in 0..<20 {
                let a = pair.source.getCharData(col: col, row: row)
                let b = pair.fresh.getCharData(col: col, row: row)
                #expect(a?.getCharacter() == b?.getCharacter(), "char \(col),\(row)")
                #expect(a?.attribute == b?.attribute, "attr \(col),\(row)")
            }
        }
    }

    @Test("A stale alt screen in the receiver is superseded")
    func preludeSupersedesStaleState() {
        let pair = Pair()
        // Put the RECEIVER into a state the snapshot must overwrite. The red
        // background is set BEFORE `?1049h`, so it is what that switch saves
        // and what the prelude's `?1049l` restores. Setting it after would
        // make the prelude's own buffer switch discard it, and the erase would
        // then run on a default background whatever the SGR reset did.
        pair.fresh.feed(text: "\u{1b}[41m\u{1b}[?1049h\u{1b}[?25lstale")
        pair.transfer("clean")
        let (_, after) = pair.states()
        #expect(!after.alternateOn)
        #expect(after.cursorVisible)
        #expect(pair.fresh.getLine(row: 0)?.translateToString(trimRight: true) == "clean")
        // The stale red background must not survive the erase: `\e[0m` has to
        // precede `\e[2J`, or ED repaints the whole screen in it. Compare
        // against the source's own untouched blank rather than naming a
        // "default" attribute, so the assertion pins the round trip and not
        // SwiftTerm's spelling of an empty cell.
        for col in 0..<10 {
            #expect(
                pair.fresh.getCharData(col: col, row: 5)?.attribute
                    == pair.source.getCharData(col: col, row: 5)?.attribute,
                "stale background survived at column \(col)")
        }
    }

    @Test("An alt-screen session round-trips, and exiting restores the primary")
    func altScreenRoundTrip() {
        let pair = Pair()
        // The saved cursor is parked away from home (`\e[s` at row 10, col 30)
        // on purpose: `assemble` positions the saved cursor before `?1049h`,
        // and with a home-position save the `\e[H` that follows would be
        // indistinguishable from doing nothing.
        pair.transfer(
            "primary text\u{1b}[?1049h\u{1b}[2J\u{1b}[Halt content\u{1b}[10;30H\u{1b}[s"
                + "\u{1b}[1;12H")
        // Snapshotting an alt-screen terminal toggles the SOURCE back to the
        // primary buffer to reach its history. That source is live production
        // state in the daemon, so it must be left exactly as it was found.
        #expect(pair.source.isCurrentBufferAlternate)
        #expect(pair.source.getLine(row: 0)?.translateToString(trimRight: true) == "alt content")
        #expect(pair.fresh.isCurrentBufferAlternate)
        #expect(pair.fresh.getLine(row: 0)?.translateToString(trimRight: true) == "alt content")
        #expect(pair.fresh.buffer.x == pair.source.buffer.x)
        #expect(pair.fresh.buffer.y == pair.source.buffer.y)
        pair.fresh.feed(text: "\u{1b}[?1049l")
        #expect(!pair.fresh.isCurrentBufferAlternate)
        #expect(pair.fresh.getLine(row: 0)?.translateToString(trimRight: true) == "primary text")
        // And the source's own primary buffer is still behind its alt screen —
        // the round trip through the history walk must not have consumed it.
        pair.source.feed(text: "\u{1b}[?1049l")
        #expect(pair.source.getLine(row: 0)?.translateToString(trimRight: true) == "primary text")
    }

    @Test("The saved cursor a receiver restores on exit is the PRIMARY one")
    func primarySavedCursorSurvivesAltScreen() {
        let pair = Pair()
        // Two saved cursors, deliberately different. `?1049h` stores the
        // primary cursor — here row 7, col 20 — for a later `?1049l` to
        // restore; the `\e[s` on the alt screen stores an unrelated second one
        // at row 10, col 30. `capture` reads whichever buffer is active, so an
        // alt-screen snapshot sees the alt one, and emitting THAT as the
        // pre-switch CUP sends a returning viewer to the wrong column on exit.
        pair.transfer(
            "primary text\u{1b}[7;20H\u{1b}[?1049h\u{1b}[2J\u{1b}[Halt content"
                + "\u{1b}[10;30H\u{1b}[s\u{1b}[1;12H")
        pair.fresh.feed(text: "\u{1b}[?1049l")
        pair.source.feed(text: "\u{1b}[?1049l")
        #expect(pair.fresh.buffer.x == pair.source.buffer.x)
        #expect(pair.fresh.buffer.y == pair.source.buffer.y)
        // Pin the absolute position too. The comparison alone would still hold
        // if both terminals agreed on the wrong cursor.
        #expect(pair.fresh.buffer.x == 19)
        #expect(pair.fresh.buffer.y == 6)
    }

    @Test("The cursor lands where it was, under origin mode and a scroll region")
    func originModeCursor() {
        let pair = Pair()
        pair.transfer("\u{1b}[5;15r\u{1b}[?6h\u{1b}[3;9H")
        #expect(pair.fresh.buffer.x == pair.source.buffer.x)
        #expect(pair.fresh.buffer.y == pair.source.buffer.y)
    }

    @Test("Scrollback above the viewport arrives")
    func scrollbackArrives() {
        let pair = Pair(cols: 40, rows: 5)
        pair.transfer((1...30).map { "row-\($0)" }.joined(separator: "\r\n"))
        // The newest scrolled-away row must be reachable above the viewport.
        var seen = false
        var row = pair.fresh.buffer.totalLinesTrimmed
        while let line = pair.fresh.getScrollInvariantLine(row: row) {
            if line.translateToString(trimRight: true) == "row-20" { seen = true }
            row += 1
        }
        #expect(seen, "scrolled-away history did not survive the snapshot")
        // A trailing `\r\n` after the history would push every row up by one,
        // so pin the viewport's absolute placement, not just reachability.
        #expect(pair.fresh.getLine(row: 0)?.translateToString(trimRight: true) == "row-26")
        #expect(pair.fresh.getLine(row: 4)?.translateToString(trimRight: true) == "row-30")
    }
}
