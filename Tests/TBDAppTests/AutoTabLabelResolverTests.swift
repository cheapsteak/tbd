import Foundation
import Testing

@testable import TBDApp
import TBDShared

@Suite("AutoTabLabelResolver")
struct AutoTabLabelResolverTests {
    @Test func codexTerminalUsesCodexLabel() {
        let terminal = Terminal(
            worktreeID: UUID(),
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: nil,
            kind: .codex
        )

        let label = AutoTabLabelResolver.terminalLabel(
            terminal: terminal,
            fallbackIndex: 1,
            modelProfiles: [],
            worktreeTabs: [],
            worktreeTerminals: []
        )

        #expect(label == "Codex")
    }

    @Test func shellTerminalUsesGenericNumberedLabel() {
        let terminal = Terminal(
            worktreeID: UUID(),
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: nil,
            kind: .shell
        )

        let label = AutoTabLabelResolver.terminalLabel(
            terminal: terminal,
            fallbackIndex: 2,
            modelProfiles: [],
            worktreeTabs: [],
            worktreeTerminals: []
        )

        #expect(label == "Terminal 3")
    }

    @Test func claudeProfileUsesProfileNameAndPosition() {
        let worktreeID = UUID()
        let profileID = UUID()
        let firstID = UUID()
        let secondID = UUID()

        let profile = ModelProfile(id: profileID, name: "Bedrock", kind: .bedrock)
        let terminals = [
            Terminal(
                id: firstID,
                worktreeID: worktreeID,
                tmuxWindowID: "@1",
                tmuxPaneID: "%1",
                claudeSessionID: "s1",
                profileID: profileID,
                kind: .claude
            ),
            Terminal(
                id: secondID,
                worktreeID: worktreeID,
                tmuxWindowID: "@2",
                tmuxPaneID: "%2",
                claudeSessionID: "s2",
                profileID: profileID,
                kind: .claude
            )
        ]
        let tabs = [
            Tab(id: firstID, content: .terminal(terminalID: firstID), label: nil),
            Tab(id: secondID, content: .terminal(terminalID: secondID), label: nil)
        ]

        let label = AutoTabLabelResolver.terminalLabel(
            terminal: terminals[1],
            fallbackIndex: 7,
            modelProfiles: [ModelProfileWithUsage(profile: profile)],
            worktreeTabs: tabs,
            worktreeTerminals: terminals
        )

        #expect(label == "Bedrock 2")
    }
}
