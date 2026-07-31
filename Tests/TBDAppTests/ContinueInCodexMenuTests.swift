import Foundation
import TBDShared
import Testing
@testable import TBDApp

@Suite("Continue in Codex tab menu")
struct ContinueInCodexMenuTests {
    private func terminal(kind: TerminalKind, sessionID: String? = nil) -> Terminal {
        Terminal(
            worktreeID: UUID(),
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            claudeSessionID: sessionID,
            kind: kind
        )
    }

    @Test func usesPlainLanguageTitle() {
        #expect(ContinueInCodexMenu.title == "Continue in Codex")
    }

    @Test func availableForResumableClaudeTerminal() {
        #expect(ContinueInCodexMenu.isAvailable(
            for: terminal(kind: .claude, sessionID: "session-1")
        ))
    }

    @Test func unavailableForCodexShellAndMissingTerminal() {
        #expect(!ContinueInCodexMenu.isAvailable(for: terminal(kind: .codex)))
        #expect(!ContinueInCodexMenu.isAvailable(for: terminal(kind: .shell)))
        #expect(!ContinueInCodexMenu.isAvailable(for: nil))
    }
}
