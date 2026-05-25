import Testing
import Foundation
@testable import TBDApp

@MainActor
struct ShouldSuppressEventsTests {
    private let t1 = UUID()
    private let t2 = UUID()

    @Test func noOverlayOpen_returnsFalse() {
        let c = TranscriptOverlayCoordinator()
        #expect(!shouldSuppressEvents(in: c, forTerminalID: t1))
    }

    @Test func itemFrame_forThisTerminal_returnsTrue() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "a")
        #expect(shouldSuppressEvents(in: c, forTerminalID: t1))
    }

    @Test func itemFrame_forDifferentTerminal_returnsFalse() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "a")
        #expect(!shouldSuppressEvents(in: c, forTerminalID: t2))
    }

    @Test func fileFrame_returnsTrueForAnyTerminal() {
        // File frames render at the window root and must suppress key
        // forwarding from EVERY terminal underneath — regression guard
        // for #199 review (Medium): file overlays previously let arrow
        // keys / letters route to the tmux terminal beneath.
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "agent")
        c.pushFile(path: "/tmp/foo.md")
        #expect(shouldSuppressEvents(in: c, forTerminalID: t1))
        #expect(shouldSuppressEvents(in: c, forTerminalID: t2))
    }

    @Test func fileFrame_withNoTerminalBoundItem_returnsTrue() {
        // History-pane case: file frame on top of a history (terminalID == nil)
        // item frame must still suppress every terminal's events.
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: nil, itemID: "agent", historySessionID: "sess-1")
        c.pushFile(path: "/tmp/foo.md")
        #expect(shouldSuppressEvents(in: c, forTerminalID: t1))
    }
}
