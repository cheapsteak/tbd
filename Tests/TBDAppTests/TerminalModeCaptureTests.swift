import Foundation
import SwiftTerm
import Testing
@testable import TBDTerminalSerialization

/// Captures replies so DECRQM can be answered, exactly as
/// SwiftTermModeEscapeSmokeTests does — no @testable import of SwiftTerm, which
/// is an external release-built package.
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

private func harness() -> (Terminal, ReplyCollector) {
    let collector = ReplyCollector()
    let terminal = Terminal(delegate: collector)
    collector.terminal = terminal
    return (terminal, collector)
}

@Suite("Terminal mode capture")
struct TerminalModeCaptureTests {
    @Test("A fresh terminal captures its documented defaults")
    func defaults() {
        let (terminal, reply) = harness()
        let state = TerminalModeCapture.capture(from: terminal, reply: reply)
        #expect(state.wraparound)           // DECAWM defaults on
        #expect(state.cursorVisible)
        #expect(!state.alternateOn)
        #expect(!state.originMode)
        #expect(!state.bracketedPaste)
        #expect(state.cols == terminal.cols)
        #expect(state.rows == terminal.rows)
    }

    @Test("Modes with no public property are read through DECRQM")
    func privateModes() {
        let (terminal, reply) = harness()
        // ?45h (reverse wraparound) must come before ?7l (autowrap off): SwiftTerm's
        // xterm-derived handler only lets reverse wraparound turn on while autowrap is
        // already on ("reverse wraparound can only be enabled if Auto-wrap is enabled"),
        // and turning autowrap back off afterward does not clear it. Feeding ?45h after
        // ?7l silently no-ops it — a discrepancy from a naive reading of the brief,
        // recorded in the task-3 report.
        terminal.feed(text: "\u{1b}[?6h\u{1b}[?45h\u{1b}[?7l\u{1b}[?25l\u{1b}[?66h\u{1b}[4h")
        let state = TerminalModeCapture.capture(from: terminal, reply: reply)
        #expect(state.originMode)
        #expect(!state.wraparound)
        #expect(!state.cursorVisible)
        #expect(state.applicationKeypad)
        #expect(state.insertMode)
        #expect(state.reverseWraparound)
    }

    @Test("Alt screen is read from the public property, not DECRQM")
    func alternateScreen() {
        // Mode 1049 is absent from cmdDecRqm's switch and answers "unknown",
        // so a capture that asked DECRQM would report false while on the alt
        // screen. This test fails against that mistake.
        let (terminal, reply) = harness()
        terminal.feed(text: "\u{1b}[?1049h")
        #expect(TerminalModeCapture.capture(from: terminal, reply: reply).alternateOn)
    }

    @Test("Cursor position and scroll region are captured")
    func cursorAndRegion() {
        let (terminal, reply) = harness()
        terminal.feed(text: "\u{1b}[5;12r\u{1b}[3;7H")
        let state = TerminalModeCapture.capture(from: terminal, reply: reply)
        #expect(state.scrollTop == 4)
        #expect(state.scrollBottom == 11)
        #expect(state.cursorX == 6)
    }

    @Test("Mouse tracking and its encoding are captured")
    func mouse() {
        let (terminal, reply) = harness()
        terminal.feed(text: "\u{1b}[?1002h\u{1b}[?1006h")
        let state = TerminalModeCapture.capture(from: terminal, reply: reply)
        #expect(state.mouseTracking == 1002)
        #expect(state.sgrMouseEncoding)
    }
}
