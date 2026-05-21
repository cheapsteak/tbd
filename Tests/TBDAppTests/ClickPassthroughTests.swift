import Testing
import AppKit
@testable import TBDApp

@Suite("Click passthrough modifier guard")
struct ClickPassthroughTests {
    @Test("plain click is not blocked")
    func plainClickAllowed() {
        #expect(TBDTerminalView.clickPassthroughBlocked(by: []) == false)
    }

    @Test("command-click is blocked")
    func commandBlocks() {
        #expect(TBDTerminalView.clickPassthroughBlocked(by: .command) == true)
    }

    @Test("shift-click is blocked")
    func shiftBlocks() {
        #expect(TBDTerminalView.clickPassthroughBlocked(by: .shift) == true)
    }

    @Test("non-intercession flags (capsLock) do not block")
    func capsLockAllowed() {
        #expect(TBDTerminalView.clickPassthroughBlocked(by: .capsLock) == false)
    }
}
