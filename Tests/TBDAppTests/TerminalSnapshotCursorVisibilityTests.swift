import Foundation
import SwiftTerm
import Testing
@testable import TBDTerminalSerialization

/// The receiving SwiftTerm fork shows the cursor on every `?1049h`, so a hidden
/// cursor must be hidden after the alt-screen switch, not before it.
@Suite("Terminal snapshot cursor visibility")
struct TerminalSnapshotCursorVisibilityTests {
    private let esc = "\u{1b}"

    @Test("A hidden cursor on an alt screen stays hidden")
    func hiddenOnAltScreen() {
        let pair = SnapshotPair()
        pair.transfer("primary text\(esc)[?1049h\(esc)[?25lalt text")
        let (before, after) = pair.states()
        #expect(before.alternateOn)
        #expect(!before.cursorVisible)
        #expect(after.alternateOn)
        #expect(!after.cursorVisible)
    }

    @Test("A visible cursor on an alt screen stays visible")
    func visibleOnAltScreen() {
        let pair = SnapshotPair()
        pair.transfer("primary text\(esc)[?1049halt text")
        let (before, after) = pair.states()
        #expect(before.alternateOn)
        #expect(before.cursorVisible)
        #expect(after.alternateOn)
        #expect(after.cursorVisible)
    }

    @Test("A hidden cursor on the primary screen stays hidden")
    func hiddenOnPrimaryScreen() {
        let pair = SnapshotPair()
        pair.transfer("primary text\(esc)[?25l")
        let (before, after) = pair.states()
        #expect(!before.alternateOn)
        #expect(!before.cursorVisible)
        #expect(!after.alternateOn)
        #expect(!after.cursorVisible)
    }

    @Test("The assembled bytes set cursor visibility after the alt-screen switch")
    func visibilityFollowsSwitch() throws {
        let pair = SnapshotPair()
        pair.source.feed(text: "x\(esc)[?1049h\(esc)[?25l")
        let state = TerminalModeCapture.capture(from: pair.source, reply: pair.sourceReply)
        #expect(state.alternateOn)
        #expect(!state.cursorVisible)

        let data = TerminalSnapshotWriter.assemble(history: "", altScreen: "", state: state)
        let text = try #require(String(data: data, encoding: .utf8))
        let switchRange = try #require(text.range(of: "\(esc)[?1049h"))
        let lastVisibility = try #require(text.range(of: "\(esc)[?25", options: .backwards))
        #expect(lastVisibility.lowerBound > switchRange.upperBound)
        #expect(text[lastVisibility.upperBound...].hasPrefix("l"))
    }
}
