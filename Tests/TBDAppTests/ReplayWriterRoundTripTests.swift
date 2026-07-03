// M4.2 — SwiftTerm round-trip for the replay assembler.
//
// The byte-level suite (Tests/TBDDaemonTests/ReplayWriterTests.swift) proves the
// assembler emits the right escapes in the right order; this suite proves those
// bytes actually produce the intended terminal STATE when fed through SwiftTerm,
// using the same headless-harness pattern as SwiftTermModeEscapeSmokeTests (M4.0).
//
// It lives in TBDAppTests because this is the only test target that links the
// SwiftTerm product; TBDDaemonLib was added to this target's dependencies for
// exactly this cross-boundary test (the app consumes the daemon's replay bytes
// at runtime, so the pairing mirrors production).
//
// Notable finding verified here (M4.0 did not cover it): SwiftTerm HONORS ED3
// (`\e[3J`, xterm scrollback clear) via `feed` — `cmdEraseInDisplay` case 3
// trims the scrollback lines — so the reset prelude fully supersedes a stale
// pre-fed snapshot, scrollback included.

import Foundation
import SwiftTerm
import Testing

@testable import TBDDaemonLib

/// Minimal headless delegate (same shape as M4.0): `Terminal.tdel` is weak,
/// so tests must hold this strongly. Only `send` lacks a default impl.
private final class ResponseCapturingDelegate: TerminalDelegate {
    var bytes: [UInt8] = []

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        bytes.append(contentsOf: data)
    }

    var text: String { String(decoding: bytes, as: UTF8.self) }

    func reset() { bytes.removeAll() }
}

/// Headless SwiftTerm harness (default 80x25).
private struct TerminalHarness {
    let delegate = ResponseCapturingDelegate()
    let terminal: Terminal

    init() {
        terminal = Terminal(delegate: delegate)
    }

    func feed(_ text: String) {
        terminal.feed(text: text)
    }

    func feed(_ data: Data) {
        terminal.feed(byteArray: [UInt8](data))
    }

    /// DECRQM round-trip (CSI ? Pd $p → CSI ? Pd ; Ps $y). Ps 1 = set, 2 = reset.
    func requestDECMode(_ mode: Int) -> Int? {
        requestMode(mode, prefix: "?")
    }

    /// ANSI-mode DECRQM (CSI Pd $p) — used for IRM (insert mode, mode 4).
    func requestANSIMode(_ mode: Int) -> Int? {
        requestMode(mode, prefix: "")
    }

    private func requestMode(_ mode: Int, prefix: String) -> Int? {
        delegate.reset()
        feed("\u{1b}[\(prefix)\(mode)$p")
        let reply = delegate.text
        guard let head = reply.range(of: "\(prefix)\(mode);"),
              let tail = reply[head.upperBound...].range(of: "$y") else {
            return nil
        }
        return Int(reply[head.upperBound..<tail.lowerBound])
    }

    /// Trimmed text of a viewport row (0-based, relative to the display).
    func rowText(_ row: Int) -> String {
        terminal.getLine(row: row)?.translateToString(trimRight: true) ?? ""
    }

    func assemble(
        history: [String] = [], altScreen: [String]? = nil, pending: [String] = [],
        state: PaneState
    ) throws -> Data {
        try ReplayWriter.assemble(
            history: history, altScreen: altScreen, pending: pending,
            state: state, cols: terminal.cols, rows: terminal.rows)
    }
}

private func makeState(
    cursorX: Int = 0, cursorY: Int = 0,
    alternateOn: Bool = false,
    alternateSavedX: Int? = nil, alternateSavedY: Int? = nil,
    scrollRegionUpper: Int = 0, scrollRegionLower: Int = 24,
    cursorVisible: Bool = true, insertMode: Bool = false,
    applicationCursorKeys: Bool = false, applicationKeypad: Bool = false,
    wraparound: Bool = true,
    mouseStandard: Bool = false, mouseButton: Bool = false,
    mouseAny: Bool = false, mouseSGR: Bool = false,
    originMode: Bool = false
) -> PaneState {
    PaneState(
        paneID: "%1", cursorX: cursorX, cursorY: cursorY,
        alternateOn: alternateOn,
        alternateSavedX: alternateSavedX, alternateSavedY: alternateSavedY,
        scrollRegionUpper: scrollRegionUpper, scrollRegionLower: scrollRegionLower,
        cursorVisible: cursorVisible, insertMode: insertMode,
        applicationCursorKeys: applicationCursorKeys, applicationKeypad: applicationKeypad,
        wraparound: wraparound,
        mouseStandard: mouseStandard, mouseButton: mouseButton,
        mouseAny: mouseAny, mouseSGR: mouseSGR,
        originMode: originMode, paneInMode: 0,
        width: 80, height: 25)
}

@Suite("ReplayWriter → SwiftTerm round trip (M4.2)")
struct ReplayWriterRoundTripTests {

    @Test("prelude supersedes a stale pre-fed snapshot — ED3 clears scrollback (finding)")
    func preludeSupersedesStaleState() throws {
        let h = TerminalHarness()

        // Simulate the stale suspend/resume snapshot the app feeds before
        // attach: 40 lines (spilling into scrollback), non-default modes, a
        // scroll region, and a dangling alt screen.
        for i in 0..<40 { h.feed("stale-\(i)\r\n") }
        #expect(h.terminal.buffer.yDisp > 0, "precondition: stale content must have scrolled")
        h.feed("\u{1b}[?1h\u{1b}[?1000h\u{1b}[?1006h\u{1b}[4h\u{1b}[?25l\u{1b}[3;20r")
        h.feed("\u{1b}[?1049hALT-JUNK")
        #expect(h.terminal.isCurrentBufferAlternate)

        let replay = try h.assemble(history: ["alpha", "beta"], state: makeState())
        h.feed(replay)

        #expect(!h.terminal.isCurrentBufferAlternate)
        // THE ED3 finding: scrollback is empty again after the prelude.
        #expect(h.terminal.buffer.yDisp == 0, "ED3 must clear the stale scrollback via feed")
        #expect(h.rowText(0) == "alpha")
        #expect(h.rowText(1) == "beta")
        #expect(h.rowText(5) == "", "stale viewport content must be gone")
        // Modes back to defaults.
        #expect(!h.terminal.applicationCursor)
        #expect(h.terminal.mouseMode == .off)
        #expect(try #require(h.requestDECMode(1006)) == 2)
        #expect(try #require(h.requestDECMode(25)) == 1)
        #expect(try #require(h.requestANSIMode(4)) == 2)
        #expect(h.terminal.buffer.scrollTop == 0)
        #expect(h.terminal.buffer.scrollBottom == h.terminal.rows - 1)
        #expect(!h.terminal.bracketedPasteMode)
    }

    @Test("primary-screen replay restores history, modes, region, and cursor")
    func primaryScreenStateRoundTrip() throws {
        let h = TerminalHarness()
        let history = (0..<30).map { "L\($0)" }
        let state = makeState(
            cursorX: 7, cursorY: 5,
            scrollRegionUpper: 2, scrollRegionLower: 20,
            cursorVisible: false, insertMode: true,
            applicationCursorKeys: true, applicationKeypad: true,
            wraparound: false, mouseButton: true, mouseSGR: true)

        h.feed(try h.assemble(history: history, state: state))

        // 30 history lines on a 25-row screen → 5 lines of scrollback.
        #expect(h.terminal.buffer.yDisp == 5)
        #expect(h.rowText(0) == "L5")
        #expect(h.rowText(24) == "L29")
        // Modes.
        #expect(h.terminal.applicationCursor)
        #expect(try #require(h.requestDECMode(66)) == 1)   // DECKPAM
        #expect(try #require(h.requestDECMode(7)) == 2)    // DECAWM off
        #expect(try #require(h.requestDECMode(25)) == 2)   // cursor hidden
        #expect(try #require(h.requestANSIMode(4)) == 1)   // IRM on
        #expect(h.terminal.mouseMode == .buttonEventTracking)
        #expect(try #require(h.requestDECMode(1006)) == 1) // SGR encoding
        // Region and cursor (absolute — origin mode off).
        #expect(h.terminal.buffer.scrollTop == 2)
        #expect(h.terminal.buffer.scrollBottom == 20)
        #expect(h.terminal.buffer.x == 7)
        #expect(h.terminal.buffer.y == 5)
    }

    @Test("origin-mode replay lands the cursor on the absolute tmux coordinates")
    func originModeCursorRoundTrip() throws {
        let h = TerminalHarness()
        let state = makeState(cursorX: 4, cursorY: 5,
                              scrollRegionUpper: 2, scrollRegionLower: 20, originMode: true)
        h.feed(try h.assemble(state: state))

        #expect(try #require(h.requestDECMode(6)) == 1)
        // tmux reported absolute (4,5); DECOM-relative CUP must still land there.
        #expect(h.terminal.buffer.x == 4)
        #expect(h.terminal.buffer.y == 5)
    }

    @Test("alt-screen replay: content, region on the ALT buffer, cursor, and 1049l restore")
    func altScreenRoundTrip() throws {
        let h = TerminalHarness()
        let altContent = (0..<25).map { "A\($0)" }
        let state = makeState(
            cursorX: 2, cursorY: 1, alternateOn: true,
            alternateSavedX: 3, alternateSavedY: 4,
            scrollRegionUpper: 2, scrollRegionLower: 20)

        h.feed(try h.assemble(history: ["one", "two"], altScreen: altContent, state: state))

        #expect(h.terminal.isCurrentBufferAlternate)
        #expect(h.rowText(0) == "A0")
        #expect(h.rowText(24) == "A24")
        // The captured region describes the CURRENT (alt) screen — SwiftTerm
        // regions are per-buffer, so it must have been applied post-1049h.
        #expect(h.terminal.buffer.scrollTop == 2)
        #expect(h.terminal.buffer.scrollBottom == 20)
        #expect(h.terminal.buffer.x == 2)
        #expect(h.terminal.buffer.y == 1)

        // Leaving the alt screen (as the pane's app eventually will) must
        // reveal the replayed primary content and the saved primary cursor.
        h.feed("\u{1b}[?1049l")
        #expect(!h.terminal.isCurrentBufferAlternate)
        #expect(h.rowText(0) == "one")
        #expect(h.rowText(1) == "two")
        #expect(h.terminal.buffer.x == 3)
        #expect(h.terminal.buffer.y == 4)
        // The alt-buffer region must not have leaked onto the primary buffer.
        #expect(h.terminal.buffer.scrollTop == 0)
        #expect(h.terminal.buffer.scrollBottom == h.terminal.rows - 1)
    }

    @Test("pending output feeds as raw bytes — octal-escaped UTF-8 renders")
    func pendingOctalPassthrough() throws {
        let h = TerminalHarness()
        // tmux -C escaping of "P日" (multi-byte UTF-8 arrives fully escaped).
        let replay = try h.assemble(pending: ["P\\346\\227\\245"], state: makeState(cursorX: 5, cursorY: 5))
        h.feed(replay)

        #expect(h.terminal.getCharacter(col: 0, row: 0) == "P")
        #expect(h.terminal.getCharacter(col: 1, row: 0) == "日")
        #expect(h.terminal.buffer.x == 5)
        #expect(h.terminal.buffer.y == 5)
    }
}
