// M4.0 — SwiftTerm mode-escape smoke test (GATE for the control-mode replay writer).
//
// The Phase A replay writer (spec: docs/specs/2026-07-02-tmux-control-mode-phase-a-addendum.md §3)
// will synthesize mode escapes from captured tmux pane state and write them into the pane's
// vended fd; the app feeds those bytes to SwiftTerm via `Terminal.feed`. Before building that
// writer we verify, headlessly (no NSView, no UI), that SwiftTerm actually APPLIES every escape
// we plan to emit.
//
// Inspectability map (SwiftTerm revision dae32cc, see Package.swift pin):
//
//   escape                      state                    how asserted
//   ---------------------------------------------------------------------------------------
//   CSI ?1049 h/l               alt/normal buffer        public `isCurrentBufferAlternate`
//                                                        + marker text survival on normal buffer
//   CSI ?1 h/l    (DECCKM)      application cursor keys  public `applicationCursor`
//   CSI ?7 h/l    (DECAWM)      autowrap                 internal `wraparound` — asserted via
//                                                        DECRQM (CSI ?7 $p) reply + observable
//                                                        wrap/no-wrap of overflowing text
//   ESC = / ESC > (DECKPAM/PNM) application keypad       internal `applicationKeypad` — asserted
//                                                        via DECRQM mode 66 reply
//   CSI 2004 h/l                bracketed paste          public `bracketedPasteMode`
//   CSI r;c H     (CUP)         cursor position          public `buffer.x` / `buffer.y` (0-based)
//   CSI t;b r     (DECSTBM)     scroll region            public `buffer.scrollTop/.scrollBottom`
//   CSI ?1000/1002/1003 h       mouse tracking mode      public `mouseMode` enum
//   CSI ?1006 h/l (SGR)         mouse encoding           private `mouseProtocol` — asserted via
//                                                        DECRQM mode 1006 reply + SGR-format
//                                                        bytes emitted by `sendEvent`
//   CSI ?25 h/l   (DECTCEM)     cursor visibility        internal `cursorHidden` — asserted via
//                                                        DECRQM mode 25 reply (1 = visible)
//
// Where a mode's backing property is not public (`wraparound`, `applicationKeypad`,
// `cursorHidden`, `mouseProtocol`), we do NOT @testable-import SwiftTerm (external package,
// release-built). Instead we round-trip through the same public `feed` path under test:
// DECRQM (`CSI ? Pd $p`) makes the terminal report the mode's state (`CSI ? Pd ; Ps $y`,
// Ps 1 = set, 2 = reset) through the delegate's `send`, which is itself proof the escape was
// parsed AND applied. No mode in scope turned out to be uninspectable.
//
// A failing assertion here is a FINDING about SwiftTerm, not a bug to paper over.

import Testing
import SwiftTerm

/// Minimal headless delegate: `Terminal.tdel` is weak, so tests must hold this strongly.
/// Only `send` has no default implementation in the `TerminalDelegate` extension.
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

    /// DECRQM round-trip: feed `CSI ? mode $p`, parse `CSI ? mode ; Ps $y` from the
    /// delegate's captured response. Returns Ps (1 = set, 2 = reset), or nil if the
    /// terminal did not answer — which would itself be a gate failure.
    func requestDECMode(_ mode: Int) -> Int? {
        delegate.reset()
        feed("\u{1b}[?\(mode)$p")
        let reply = delegate.text
        guard let head = reply.range(of: "?\(mode);"),
              let tail = reply[head.upperBound...].range(of: "$y") else {
            return nil
        }
        return Int(reply[head.upperBound..<tail.lowerBound])
    }
}

@Suite("SwiftTerm mode-escape smoke (M4.0 replay gate)")
struct SwiftTermModeEscapeSmokeTests {

    // MARK: 1049 — alternate screen buffer

    @Test("CSI ?1049h/l switches to the alt buffer and back, preserving normal-buffer content")
    func altScreenSwitch() throws {
        let h = TerminalHarness()
        #expect(!h.terminal.isCurrentBufferAlternate)

        h.feed("MARKER")
        h.feed("\u{1b}[?1049h")
        #expect(h.terminal.isCurrentBufferAlternate)
        // 1049 clears the alt buffer on entry: row 0 must not show normal-buffer text.
        let altTopLeft = h.terminal.getCharacter(col: 0, row: 0)
        #expect(altTopLeft != "M")

        // Content written on the alt buffer must not leak back to normal.
        h.feed("\u{1b}[10;1HALTONLY")
        h.feed("\u{1b}[?1049l")
        #expect(!h.terminal.isCurrentBufferAlternate)
        #expect(h.terminal.getCharacter(col: 0, row: 0) == "M")
        #expect(h.terminal.getCharacter(col: 0, row: 9) != "A")
    }

    // MARK: DECCKM — application cursor keys

    @Test("CSI ?1h/l toggles DECCKM application cursor keys")
    func applicationCursorKeys() {
        let h = TerminalHarness()
        #expect(!h.terminal.applicationCursor)

        h.feed("\u{1b}[?1h")
        #expect(h.terminal.applicationCursor)

        h.feed("\u{1b}[?1l")
        #expect(!h.terminal.applicationCursor)
    }

    // MARK: DECAWM — autowrap

    @Test("CSI ?7l/h toggles autowrap (DECRQM mode 7)")
    func autowrapModeReported() throws {
        let h = TerminalHarness()

        h.feed("\u{1b}[?7l")
        #expect(try #require(h.requestDECMode(7)) == 2)

        h.feed("\u{1b}[?7h")
        #expect(try #require(h.requestDECMode(7)) == 1)
    }

    @Test("autowrap off pins overflowing text to the last column; on wraps to the next row")
    func autowrapObservableBehavior() {
        let h = TerminalHarness()
        let overflow = String(repeating: "x", count: h.terminal.cols + 1)

        h.feed("\u{1b}[?7l")
        h.feed("\u{1b}[1;1H")
        h.feed(overflow)
        #expect(h.terminal.buffer.y == 0, "wraparound off must not advance to the next row")

        h.feed("\u{1b}[2J\u{1b}[?7h")
        h.feed("\u{1b}[1;1H")
        h.feed(overflow)
        #expect(h.terminal.buffer.y == 1, "wraparound on must wrap the cols+1-th char to row 1")
    }

    // MARK: DECKPAM / DECKPNM — application keypad

    @Test("ESC = / ESC > toggles application keypad (DECRQM mode 66)")
    func applicationKeypad() throws {
        let h = TerminalHarness()

        h.feed("\u{1b}=")
        #expect(try #require(h.requestDECMode(66)) == 1)

        h.feed("\u{1b}>")
        #expect(try #require(h.requestDECMode(66)) == 2)
    }

    // MARK: 2004 — bracketed paste

    @Test("CSI ?2004h/l toggles bracketed paste mode")
    func bracketedPaste() {
        let h = TerminalHarness()
        #expect(!h.terminal.bracketedPasteMode)

        h.feed("\u{1b}[?2004h")
        #expect(h.terminal.bracketedPasteMode)

        h.feed("\u{1b}[?2004l")
        #expect(!h.terminal.bracketedPasteMode)
    }

    // MARK: CUP — cursor position

    @Test("CSI row;col H positions the cursor (1-based escape, 0-based buffer)")
    func cursorPosition() {
        let h = TerminalHarness()

        h.feed("\u{1b}[5;10H")
        #expect(h.terminal.buffer.y == 4)
        #expect(h.terminal.buffer.x == 9)

        // Defaults: CSI H homes to 0,0.
        h.feed("\u{1b}[H")
        #expect(h.terminal.buffer.y == 0)
        #expect(h.terminal.buffer.x == 0)
    }

    // MARK: DECSTBM — scroll region

    @Test("CSI top;bottom r sets the scroll region and homes the cursor")
    func scrollRegion() {
        let h = TerminalHarness()
        h.feed("\u{1b}[5;10H") // move away from home so the homing side-effect is visible

        h.feed("\u{1b}[3;20r")
        #expect(h.terminal.buffer.scrollTop == 2)
        #expect(h.terminal.buffer.scrollBottom == 19)
        // DECSTBM homes the cursor — the replay writer must emit DECSTBM BEFORE
        // the final cursor-position escape, or the restored cursor gets clobbered.
        #expect(h.terminal.buffer.x == 0)
        #expect(h.terminal.buffer.y == 0)

        // CSI r resets to full screen.
        h.feed("\u{1b}[r")
        #expect(h.terminal.buffer.scrollTop == 0)
        #expect(h.terminal.buffer.scrollBottom == h.terminal.rows - 1)
    }

    // MARK: mouse tracking modes

    @Test("CSI ?1000h/?1002h/?1003h select the corresponding mouse tracking mode")
    func mouseTrackingModes() {
        let h = TerminalHarness()
        #expect(h.terminal.mouseMode == .off)

        h.feed("\u{1b}[?1000h")
        #expect(h.terminal.mouseMode == .vt200)

        h.feed("\u{1b}[?1002h")
        #expect(h.terminal.mouseMode == .buttonEventTracking)

        h.feed("\u{1b}[?1003h")
        #expect(h.terminal.mouseMode == .anyEvent)

        h.feed("\u{1b}[?1003l")
        #expect(h.terminal.mouseMode == .off)
    }

    @Test("CSI ?1006h/l toggles SGR mouse encoding (DECRQM mode 1006)")
    func sgrMouseEncodingReported() throws {
        let h = TerminalHarness()
        #expect(try #require(h.requestDECMode(1006)) == 2)

        h.feed("\u{1b}[?1006h")
        #expect(try #require(h.requestDECMode(1006)) == 1)

        h.feed("\u{1b}[?1006l")
        #expect(try #require(h.requestDECMode(1006)) == 2)
    }

    @Test("with SGR encoding on, mouse events are emitted in CSI < ... M format")
    func sgrMouseEncodingObservableBehavior() {
        let h = TerminalHarness()
        h.feed("\u{1b}[?1000h\u{1b}[?1006h")

        h.delegate.reset()
        let button = h.terminal.encodeButton(button: 0, release: false, shift: false, meta: false, control: false)
        h.terminal.sendEvent(buttonFlags: button, x: 4, y: 9)
        // SGR press at 0-based (4,9) → 1-based "CSI <0;5;10M"
        #expect(h.delegate.text.contains("<0;5;10M"))
    }

    // MARK: DECTCEM — cursor visibility

    @Test("CSI ?25l/h toggles cursor visibility (DECRQM mode 25, 1 = visible)")
    func cursorVisibility() throws {
        let h = TerminalHarness()
        #expect(try #require(h.requestDECMode(25)) == 1)

        h.feed("\u{1b}[?25l")
        #expect(try #require(h.requestDECMode(25)) == 2)

        h.feed("\u{1b}[?25h")
        #expect(try #require(h.requestDECMode(25)) == 1)
    }
}
