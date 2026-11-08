import Foundation
import SwiftTerm
import Testing
@testable import TBDTerminalSerialization

/// One mode `?1049h` saves with the cursor, and the value a fixture sets it to:
/// the one that is not the terminal's default.
struct SnapshotSavedModeCase: Sendable, CustomTestStringConvertible {
    let mode: Int
    let setValue: Bool
    var sequence: String { "\u{1b}[?\(mode)\(setValue ? "h" : "l")" }
    var testDescription: String { "?\(mode)\(setValue ? "h" : "l")" }

    static let all = [
        SnapshotSavedModeCase(mode: 6, setValue: true),
        SnapshotSavedModeCase(mode: 7, setValue: false),
        SnapshotSavedModeCase(mode: 45, setValue: true),
        SnapshotSavedModeCase(mode: 69, setValue: true),
    ]
}

/// SwiftTerm's `?1049h` saves DECOM, DECAWM, reverse wraparound and DECLRMM
/// with the cursor, and `?1049l` restores them. So a snapshot of an alt screen
/// must put the primary's saved values in place before its switch and the
/// program's after it. Otherwise the receiver's primary comes back on exit
/// with modes the source's does not have.
@Suite("Terminal snapshot alt-screen saved modes")
struct TerminalSnapshotAltScreenSavedModeTests {
    private let esc = "\u{1b}"

    /// DECRQM's answer as a Bool: 1 is set, 2 is reset, anything else is nil.
    private func isSet(_ mode: Int, in reply: SnapshotReplyCollector) -> Bool? {
        switch reply.requestMode(mode, decPrivate: true) {
        case 1: true
        case 2: false
        default: nil
        }
    }

    @Test("A mode the program sets stays on the alt screen, and exiting restores the primary's",
          arguments: SnapshotSavedModeCase.all)
    func programModeDoesNotLeakIntoThePrimary(_ saved: SnapshotSavedModeCase) {
        let pair = SnapshotPair()
        pair.transfer("\(esc)[?1049h\(saved.sequence)full-screen program")
        // The fixture has to have taken on the source, or the rest asserts
        // nothing: `?45h` is a silent no-op while autowrap is off.
        #expect(isSet(saved.mode, in: pair.sourceReply) == saved.setValue)

        #expect(pair.fresh.isCurrentBufferAlternate)
        #expect(isSet(saved.mode, in: pair.freshReply) == saved.setValue,
                "the alt screen lost the program's ?\(saved.mode)")

        pair.fresh.feed(text: "\(esc)[?1049l")
        pair.source.feed(text: "\(esc)[?1049l")
        #expect(!pair.fresh.isCurrentBufferAlternate)
        #expect(isSet(saved.mode, in: pair.freshReply) == !saved.setValue,
                "the program's ?\(saved.mode) leaked into the primary on exit")
        // The source agrees, so the expectation above is what the session
        // itself does on exit and not a guess at a default.
        #expect(isSet(saved.mode, in: pair.sourceReply) == !saved.setValue)
    }

    // Guards against the writer falling back to default mode values for the
    // primary screen. The program never touches the mode here, so this does
    // not pin the alt-screen leak; the other tests in this file do that.
    @Test("A mode the shell set before the program started is still set after it exits",
          arguments: SnapshotSavedModeCase.all)
    func shellModeSurvivesTheProgram(_ saved: SnapshotSavedModeCase) {
        let pair = SnapshotPair()
        // `tput rmam` and its kin: the primary's own value, which `?1049h`
        // saves and which the program never touches.
        pair.transfer("\(saved.sequence)\(esc)[?1049hfull-screen program")
        #expect(isSet(saved.mode, in: pair.sourceReply) == saved.setValue)
        #expect(isSet(saved.mode, in: pair.freshReply) == saved.setValue)

        pair.fresh.feed(text: "\(esc)[?1049l")
        pair.source.feed(text: "\(esc)[?1049l")
        #expect(isSet(saved.mode, in: pair.freshReply) == saved.setValue,
                "the shell's ?\(saved.mode) was lost when the program exited")
        #expect(isSet(saved.mode, in: pair.sourceReply) == saved.setValue)
    }

    @Test("Origin mode set on the alt screen stays there, and exiting restores the primary's")
    func altOriginModeDoesNotLeakIntoThePrimary() {
        let pair = SnapshotPair()
        // The primary cursor is parked at row 7, col 20 so its restore on exit
        // is visible. On the alt screen the region is rows 5-15, and under
        // `?6h` the CUP to 3;9 is region-relative: row 7 absolute, col 9, and
        // the text moves the cursor on to col 28.
        pair.transfer(
            "primary text\(esc)[7;20H\(esc)[?1049h\(esc)[5;15r\(esc)[?6h\(esc)[3;9H"
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

        pair.fresh.feed(text: "\(esc)[?1049l")
        pair.source.feed(text: "\(esc)[?1049l")
        #expect(isSet(6, in: pair.freshReply) == false,
                "the program's ?6h leaked into the primary on exit")
        #expect(isSet(6, in: pair.sourceReply) == false)
        #expect(pair.fresh.buffer.x == 19)
        #expect(pair.fresh.buffer.y == 6)
        #expect(pair.fresh.buffer.x == pair.source.buffer.x)
        #expect(pair.fresh.buffer.y == pair.source.buffer.y)
    }

    @Test("Reverse wraparound set before autowrap goes off survives, over a primary without autowrap")
    func reverseWraparoundSurvivesAutowrapOff() {
        let pair = SnapshotPair()
        // The primary has autowrap off, so after the receiver's `?1049h` it is
        // off too until the writer turns it on. `?45h` only lands while it is
        // on, on the receiver and on the source's own repaint alike.
        pair.transfer(
            "\(esc)[?7l\(esc)[?1049h\(esc)[?7h\(esc)[?45h\(esc)[?7lfull-screen program")
        #expect(isSet(45, in: pair.sourceReply) == true, "the source's repaint lost ?45h")
        #expect(isSet(7, in: pair.sourceReply) == false)
        #expect(isSet(45, in: pair.freshReply) == true, "the alt screen lost ?45h")
        #expect(isSet(7, in: pair.freshReply) == false)
    }

    @Test("A wrapped alt-screen row survives a snapshot taken with autowrap off")
    func wrappedAltRowSurvivesAutowrapOff() {
        let pair = SnapshotPair(cols: 20, rows: 5)
        // A 30-character line wraps onto a second row while autowrap is on;
        // then the program turns it off, over a primary that has it off too.
        // The alt content re-wraps that row only if autowrap is on while it
        // paints, on the receiver and on the source's own repaint alike.
        pair.transfer(
            "\(esc)[?7l\(esc)[?1049h\(esc)[?7habcdefghijklmnopqrstuvwxyz0123\(esc)[?7l")
        for row in 0..<3 {
            #expect(
                pair.fresh.getLine(row: row)?.translateToString(trimRight: true)
                    == pair.source.getLine(row: row)?.translateToString(trimRight: true),
                "row \(row) differs")
        }
        // Pin the rows themselves. The comparison alone would still hold if
        // both terminals had overwritten the last column.
        #expect(pair.source.getLine(row: 0)?.translateToString(trimRight: true)
            == "abcdefghijklmnopqrst")
        #expect(pair.source.getLine(row: 1)?.translateToString(trimRight: true) == "uvwxyz0123")
        #expect(pair.fresh.getLine(row: 0)?.translateToString(trimRight: true)
            == "abcdefghijklmnopqrst")
        #expect(pair.fresh.getLine(row: 1)?.translateToString(trimRight: true) == "uvwxyz0123")
        #expect(isSet(7, in: pair.freshReply) == false)
    }
}
