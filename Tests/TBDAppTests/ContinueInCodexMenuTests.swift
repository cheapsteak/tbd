import Foundation
import Testing
@testable import TBDApp
import TBDShared

@Suite("Continue in Codex menu visibility")
struct ContinueInCodexMenuTests {
    private func terminal(
        kind: TerminalKind,
        transcriptPath: String? = nil
    ) -> Terminal {
        Terminal(
            worktreeID: UUID(),
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            claudeSessionID: kind == .claude ? "session-1" : nil,
            transcriptPath: transcriptPath,
            kind: kind)
    }

    @Test("visible for a Claude tab with a transcript")
    func visibleForImportableClaude() {
        #expect(ContinueInCodexMenu.isVisible(for: terminal(
            kind: .claude,
            transcriptPath: "/tmp/session.jsonl")))
    }

    @Test("hidden until Claude publishes a transcript path")
    func hiddenWithoutTranscript() {
        #expect(!ContinueInCodexMenu.isVisible(for: terminal(kind: .claude)))
        #expect(!ContinueInCodexMenu.isVisible(for: terminal(
            kind: .claude,
            transcriptPath: "")))
    }

    @Test("hidden for Codex and shell tabs")
    func hiddenForOtherTerminalKinds() {
        #expect(!ContinueInCodexMenu.isVisible(for: terminal(
            kind: .codex,
            transcriptPath: "/tmp/session.jsonl")))
        #expect(!ContinueInCodexMenu.isVisible(for: terminal(
            kind: .shell,
            transcriptPath: "/tmp/session.jsonl")))
        #expect(!ContinueInCodexMenu.isVisible(for: nil))
    }
}
