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
}
