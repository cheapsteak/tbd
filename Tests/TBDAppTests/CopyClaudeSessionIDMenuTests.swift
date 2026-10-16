import Foundation
import Testing
@testable import TBDApp
import TBDShared

@Suite("Copy Session ID tab menu item")
struct CopyClaudeSessionIDMenuTests {
    private func terminal(kind: TerminalKind?, sessionID: String?) -> Terminal {
        Terminal(
            worktreeID: UUID(),
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            claudeSessionID: sessionID,
            kind: kind)
    }

    @Test("offers the session ID of a Claude tab")
    func claudeTabYieldsSessionID() {
        let id = "3f2b1c9e-0000-4000-8000-000000000001"
        #expect(CopyClaudeSessionIDMenu.sessionID(
            for: terminal(kind: .claude, sessionID: id)) == id)
    }

    @Test("hidden until the Claude session ID is known")
    func hiddenWithoutSessionID() {
        #expect(CopyClaudeSessionIDMenu.sessionID(
            for: terminal(kind: .claude, sessionID: nil)) == nil)
        #expect(CopyClaudeSessionIDMenu.sessionID(
            for: terminal(kind: .claude, sessionID: "")) == nil)
    }

    @Test("hidden for Codex, shell, and terminal-less tabs")
    func hiddenForOtherTabs() {
        #expect(CopyClaudeSessionIDMenu.sessionID(
            for: terminal(kind: .codex, sessionID: "s")) == nil)
        #expect(CopyClaudeSessionIDMenu.sessionID(
            for: terminal(kind: .shell, sessionID: "s")) == nil)
        #expect(CopyClaudeSessionIDMenu.sessionID(for: nil) == nil)
    }
}
