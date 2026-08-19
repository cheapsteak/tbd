import Testing
import Foundation
@testable import TBDShared

@Suite struct ANSIEscapeTests {
    @Test func stripsSGRColorSequences() {
        // Red "error" + reset, dim divider — all escapes gone, text kept.
        let raw = "\u{1B}[31merror\u{1B}[0m: something\n\u{1B}[2m── divider ──\u{1B}[0m"
        #expect(ANSIEscape.strip(raw) == "error: something\n── divider ──")
    }

    @Test func stripsOSCTitleSequences() {
        // OSC 0 (set window title) terminated by BEL, then by ST.
        let bel = "\u{1B}]0;my title\u{07}prompt$ "
        #expect(ANSIEscape.strip(bel) == "prompt$ ")
        let st = "\u{1B}]0;t\u{1B}\\done"
        #expect(ANSIEscape.strip(st) == "done")
    }

    @Test func leavesPlainTextUntouched() {
        let plain = "no escapes here\njust text"
        #expect(ANSIEscape.strip(plain) == plain)
    }

    // MARK: - Widened coverage (measured against a real `claude --cloud` pty capture)

    /// Save/restore cursor: `ESC 7` / `ESC 8`. Two-byte, no `[`, so the
    /// original CSI-only pattern never matched them.
    @Test func stripsTwoByteSaveRestoreCursorSequences() {
        let raw = "\u{1B}7before\u{1B}8after"
        #expect(ANSIEscape.strip(raw) == "beforeafter")
    }

    /// Charset designation: `ESC ( B` (US ASCII) and `ESC ) 0` (line
    /// drawing) — an intermediate byte (`(`/`)`) followed by a final byte,
    /// the three-byte form the CSI/OSC-only pattern also missed.
    @Test func stripsCharsetSelectorSequences() {
        let raw = "\u{1B}(Bplain\u{1B})0lines"
        #expect(ANSIEscape.strip(raw) == "plainlines")
    }

    /// CSI private-parameter prefixes `<`, `>`, `=` (Kitty keyboard-protocol
    /// queries and modifyOtherKeys replies) — legal CSI parameter bytes the
    /// original `[0-9;?]*` class excluded, so the whole sequence fell through
    /// to `[@-~]` and never matched at all.
    @Test func stripsCSIPrivateParameterPrefixedSequences() {
        let raw = "\u{1B}[<u\u{1B}[>1u\u{1B}[>4;2mCreated"
        #expect(ANSIEscape.strip(raw) == "Created")
    }

    /// The exact leading bytes measured from a real `claude --cloud` pty
    /// capture (`claude` 2.1.235, `TERM=xterm-256color COLUMNS=400
    /// LINES=200`) ahead of its first printed line. Built by explicit
    /// concatenation, not a string literal, so every control byte and escape
    /// sequence is unambiguous. `^D` here is two literal characters (caret,
    /// `D`) left by the `script` capture tool, not the 0x04 control byte —
    /// deliberately left untouched, since ANSIEscape strips escape sequences
    /// and C0 controls, not printable capture-tool artifacts.
    @Test func stripsTheMeasuredCloudCreateLeadInIntact() {
        let raw = "^D" + "\u{08}\u{08}"
            + "\u{1B}7" + "\u{1B}[r" + "\u{1B}8"
            + "\u{1B}[?25h" + "\u{1B}[?25l" + "\u{1B}[?2004h" + "\u{1B}[?1004h" + "\u{1B}[?2031h"
            + "\u{1B}[<u" + "\u{1B}[>1u" + "\u{1B}[>4;2m" + "\u{1B}[>0q"
            + "Created cloud session: Probe reply OK then stop"
        #expect(ANSIEscape.strip(raw) == "^D\u{08}\u{08}Created cloud session: Probe reply OK then stop")
    }
}
