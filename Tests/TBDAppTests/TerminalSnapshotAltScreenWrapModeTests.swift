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
}
