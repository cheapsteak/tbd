import Foundation
import SwiftTerm
import Testing
@testable import TBDTerminalSerialization

/// One wrap mode an alt-screen program sets, and the primary's value for it.
struct SnapshotWrapModeCase: Sendable, CustomTestStringConvertible {
    let mode: Int
    /// What the full-screen program sets once it is on the alt screen.
    let altValue: Bool
    /// The primary's value, which nothing in the fixture changes.
    let primaryValue: Bool
    var testDescription: String { "?\(mode)\(altValue ? "h" : "l")" }

    static let all = [
        SnapshotWrapModeCase(mode: 7, altValue: false, primaryValue: true),
        SnapshotWrapModeCase(mode: 45, altValue: true, primaryValue: false),
        SnapshotWrapModeCase(mode: 69, altValue: true, primaryValue: false),
    ]
}

/// SwiftTerm's `?1049h` saves DECAWM, reverse wraparound and DECLRMM with the
/// cursor, and `?1049l` restores them. So a snapshot of an alt screen must put
/// the primary's values in place before its switch and the program's after it,
/// or the receiver keeps the program's values on the primary once it exits.
@Suite("Terminal snapshot alt-screen wrap modes")
struct TerminalSnapshotAltScreenWrapModeTests {
    /// DECRQM's answer as a Bool: 1 is set, 2 is reset, anything else is nil.
    private func isSet(_ mode: Int, in reply: SnapshotReplyCollector) -> Bool? {
        switch reply.requestMode(mode, decPrivate: true) {
        case 1: true
        case 2: false
        default: nil
        }
    }

    @Test("A wrap mode set on the alt screen stays there, and exiting restores the primary's",
          arguments: SnapshotWrapModeCase.all)
    func altWrapModeDoesNotLeakIntoThePrimary(_ wrap: SnapshotWrapModeCase) {
        let pair = SnapshotPair()
        pair.transfer(
            "\u{1b}[?1049h\u{1b}[?\(wrap.mode)\(wrap.altValue ? "h" : "l")full-screen program")
        // The fixture has to have taken on the source, or the rest asserts
        // nothing: `?45h` is a silent no-op while autowrap is off.
        #expect(isSet(wrap.mode, in: pair.sourceReply) == wrap.altValue)

        #expect(pair.fresh.isCurrentBufferAlternate)
        #expect(isSet(wrap.mode, in: pair.freshReply) == wrap.altValue,
                "the alt screen lost the program's ?\(wrap.mode)")

        pair.fresh.feed(text: "\u{1b}[?1049l")
        pair.source.feed(text: "\u{1b}[?1049l")
        #expect(!pair.fresh.isCurrentBufferAlternate)
        #expect(isSet(wrap.mode, in: pair.freshReply) == wrap.primaryValue,
                "the program's ?\(wrap.mode) leaked into the primary on exit")
        // The source agrees, so the expectation above is what the session
        // itself does on exit and not a guess at a default.
        #expect(isSet(wrap.mode, in: pair.sourceReply) == wrap.primaryValue)
    }

    @Test("Origin mode set on the alt screen stays there, and exiting restores the primary's")
    func altOriginModeDoesNotLeakIntoThePrimary() {
        let pair = SnapshotPair()
        // The primary cursor is parked at row 7, col 20 so its restore on exit
        // is visible. On the alt screen the region is rows 5-15, and under
        // `?6h` the CUP to 3;9 is region-relative: row 7 absolute, col 9, and
        // the text moves the cursor on to col 28.
        pair.transfer(
            "primary text\u{1b}[7;20H\u{1b}[?1049h\u{1b}[5;15r\u{1b}[?6h\u{1b}[3;9H"
                + "full-screen program")
        #expect(isSet(6, in: pair.sourceReply) == true)

        #expect(pair.fresh.isCurrentBufferAlternate)
        #expect(isSet(6, in: pair.freshReply) == true, "the alt screen lost the program's ?6h")
        #expect(pair.fresh.buffer.x == pair.source.buffer.x)
        #expect(pair.fresh.buffer.y == pair.source.buffer.y)
        // Pin the cell too. The comparison alone would still hold if both
        // terminals agreed on the wrong one.
        #expect(pair.fresh.buffer.x == 27)
        #expect(pair.fresh.buffer.y == 6)

        pair.fresh.feed(text: "\u{1b}[?1049l")
        pair.source.feed(text: "\u{1b}[?1049l")
        #expect(isSet(6, in: pair.freshReply) == false,
                "the program's ?6h leaked into the primary on exit")
        #expect(isSet(6, in: pair.sourceReply) == false)
        #expect(pair.fresh.buffer.x == 19)
        #expect(pair.fresh.buffer.y == 6)
        #expect(pair.fresh.buffer.x == pair.source.buffer.x)
        #expect(pair.fresh.buffer.y == pair.source.buffer.y)
    }
}
