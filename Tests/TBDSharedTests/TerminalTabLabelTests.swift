import Foundation
import Testing
@testable import TBDShared

@Suite("TerminalTabLabel")
struct TerminalTabLabelTests {
    private static func terminal(
        label: String? = nil, claudeSessionID: String? = nil, profileID: UUID? = nil,
        kind: TerminalKind? = nil
    ) -> TBDShared.Terminal {
        TBDShared.Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1", label: label,
            claudeSessionID: claudeSessionID, profileID: profileID, kind: kind)
    }

    @Test func aProfileTabIsNamedByProfileAndPosition() {
        let profile = ModelProfile(name: "Work", kind: .oauth)
        let first = Self.terminal(claudeSessionID: "s1", profileID: profile.id, kind: .claude)
        let other = Self.terminal(claudeSessionID: "s2", kind: .claude)
        let second = Self.terminal(claudeSessionID: "s3", profileID: profile.id, kind: .claude)
        let label = TerminalTabLabel.automatic(
            terminal: second, fallbackIndex: 2, profiles: [profile],
            orderedTerminalIDs: [first.id, other.id, second.id],
            worktreeTerminals: [first, other, second])
        #expect(label == "Work 2")
    }

    @Test func aClaudeTabWithoutProfileIsClaude() {
        let claude = Self.terminal(claudeSessionID: "s1", kind: .claude)
        let label = TerminalTabLabel.automatic(
            terminal: claude, fallbackIndex: 0, profiles: [],
            orderedTerminalIDs: [claude.id], worktreeTerminals: [claude])
        #expect(label == "Claude")
    }

    @Test func aCodexTabIsCodex() {
        let codex = Self.terminal(kind: .codex)
        let label = TerminalTabLabel.automatic(
            terminal: codex, fallbackIndex: 0, profiles: [],
            orderedTerminalIDs: [codex.id], worktreeTerminals: [codex])
        #expect(label == TerminalLabel.codex)
    }

    @Test func aSetupTabIsSetup() {
        let setup = Self.terminal(label: "setup", kind: .shell)
        let label = TerminalTabLabel.automatic(
            terminal: setup, fallbackIndex: 0, profiles: [],
            orderedTerminalIDs: [setup.id], worktreeTerminals: [setup])
        #expect(label == "Setup")
    }

    @Test func anythingElseIsNumbered() {
        let shell = Self.terminal(kind: .shell)
        let label = TerminalTabLabel.automatic(
            terminal: shell, fallbackIndex: 2, profiles: [],
            orderedTerminalIDs: [shell.id], worktreeTerminals: [shell])
        #expect(label == "Terminal 3")
        let none = TerminalTabLabel.automatic(
            terminal: nil, fallbackIndex: 2, profiles: [],
            orderedTerminalIDs: [], worktreeTerminals: [])
        #expect(none == "Terminal 3")
    }
}
