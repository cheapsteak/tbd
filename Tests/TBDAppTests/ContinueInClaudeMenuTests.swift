import Foundation
import Testing
@testable import TBDApp
import TBDShared

@Suite("Continue in Claude menu")
struct ContinueInClaudeMenuTests {
    private func terminal(
        kind: TerminalKind = .codex,
        transcriptPath: String? = "/tmp/codex-rollout.jsonl",
        activityState: TerminalActivityState = .idle,
        transport: TerminalTransport = .tmux
    ) -> Terminal {
        Terminal(
            worktreeID: UUID(),
            tmuxWindowID: transport == .tmux ? "@1" : "",
            tmuxPaneID: transport == .tmux ? "%1" : "",
            transcriptPath: transcriptPath,
            kind: kind,
            activityState: activityState,
            transport: transport)
    }

    @Test("visible only for tmux Codex rows with a rollout")
    func visibility() {
        #expect(ContinueInClaudeMenu.isVisible(for: terminal()))
        #expect(!ContinueInClaudeMenu.isVisible(for: terminal(transcriptPath: nil)))
        #expect(!ContinueInClaudeMenu.isVisible(for: terminal(transcriptPath: "")))
        #expect(!ContinueInClaudeMenu.isVisible(for: terminal(transport: .holder)))
        #expect(!ContinueInClaudeMenu.isVisible(for: terminal(kind: .claude)))
        #expect(!ContinueInClaudeMenu.isVisible(for: terminal(kind: .shell)))
        #expect(!ContinueInClaudeMenu.isVisible(for: nil))
    }

    @Test("only positively idle Codex rows enable account choices")
    func activityRail() {
        #expect(ContinueInClaudeMenu.isEnabled(for: terminal(activityState: .idle)))
        #expect(!ContinueInClaudeMenu.isEnabled(for: terminal(activityState: .working)))
        #expect(!ContinueInClaudeMenu.isEnabled(for: terminal(activityState: .waitingForUser)))
        #expect(!ContinueInClaudeMenu.isEnabled(for: terminal(activityState: .unknown)))
    }

    @Test("disabled choices explain that the turn must finish")
    func busyCaption() {
        #expect(ContinueInClaudeMenu.caption(
            for: terminal(activityState: .working)) == ContinueInClaudeMenu.busyCaption)
        #expect(ContinueInClaudeMenu.caption(
            for: terminal(activityState: .waitingForUser)) == ContinueInClaudeMenu.busyCaption)
        #expect(ContinueInClaudeMenu.caption(
            for: terminal(activityState: .unknown)) == ContinueInClaudeMenu.busyCaption)
        #expect(ContinueInClaudeMenu.caption(for: terminal(activityState: .idle)) == nil)
        #expect(ContinueInClaudeMenu.caption(for: nil) == nil)
    }
}

@MainActor
@Suite("Continue in Claude replacement delta")
struct ContinueInClaudeReplacementDeltaTests {
    @Test("replaces the cached row without moving the selected tab or layout")
    func preservesTabIdentity() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        let tabID = UUID()
        let siblingPaneID = UUID()
        let splitID = UUID()
        let source = Terminal(
            id: terminalID,
            worktreeID: worktreeID,
            tmuxWindowID: "@4",
            tmuxPaneID: "%7",
            label: "Codex",
            transcriptPath: "/tmp/codex-rollout.jsonl",
            kind: .codex,
            activityState: .idle)
        let replacement = Terminal(
            id: terminalID,
            worktreeID: worktreeID,
            tmuxWindowID: "@4",
            tmuxPaneID: "%8",
            label: "Claude",
            claudeSessionID: "claude-session",
            profileID: UUID(),
            transcriptPath: "/tmp/claude-session.jsonl",
            kind: .claude,
            activityState: .idle)
        let layout = PaneLayout.split(
            id: splitID,
            direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: terminalID)),
                .pane(.note(noteID: siblingPaneID)),
            ],
            ratios: [0.6, 0.4])
        state.terminals[worktreeID] = [source]
        state.tabs[worktreeID] = [
            Tab(id: tabID, content: .terminal(terminalID: terminalID), label: "Captain"),
        ]
        state.layouts[tabID] = layout
        state.activeTabIndices[worktreeID] = 0

        state.handleDelta(.terminalReplaced(replacement))

        #expect(state.terminals[worktreeID] == [replacement])
        #expect(state.tabs[worktreeID] == [
            Tab(id: tabID, content: .terminal(terminalID: terminalID), label: "Captain"),
        ])
        #expect(state.layouts[tabID] == layout)
        #expect(state.activeTabIndices[worktreeID] == 0)
    }

    @Test("unknown replacement rows are not appended as new tabs")
    func ignoresUnknownTerminal() {
        let state = AppState()
        let worktreeID = UUID()
        let terminal = Terminal(
            worktreeID: worktreeID,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            claudeSessionID: "claude-session",
            kind: .claude)
        state.terminals[worktreeID] = []

        state.handleDelta(.terminalReplaced(terminal))

        #expect(state.terminals[worktreeID]?.isEmpty == true)
        #expect(state.tabs[worktreeID] == nil)
    }

    @Test("the generated Codex label becomes profile-aware while a custom label survives")
    func updatesOnlyGeneratedProviderLabel() {
        let state = AppState()
        let worktreeID = UUID()
        let generatedID = UUID()
        let customID = UUID()
        let generatedSource = Terminal(
            id: generatedID,
            worktreeID: worktreeID,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: "Codex",
            transcriptPath: "/tmp/generated.jsonl",
            kind: .codex,
            activityState: .idle)
        let customSource = Terminal(
            id: customID,
            worktreeID: worktreeID,
            tmuxWindowID: "@2",
            tmuxPaneID: "%2",
            label: "Codex",
            transcriptPath: "/tmp/custom.jsonl",
            kind: .codex,
            activityState: .idle)
        state.terminals[worktreeID] = [generatedSource, customSource]
        state.tabs[worktreeID] = [
            Tab(
                id: generatedID,
                content: .terminal(terminalID: generatedID),
                label: "Codex"),
            Tab(
                id: customID,
                content: .terminal(terminalID: customID),
                label: "My captain"),
        ]

        for source in [generatedSource, customSource] {
            let replacement = Terminal(
                id: source.id,
                worktreeID: worktreeID,
                tmuxWindowID: source.tmuxWindowID,
                tmuxPaneID: source.tmuxPaneID,
                label: "Claude",
                claudeSessionID: "claude-\(source.id)",
                transcriptPath: "/tmp/claude-\(source.id).jsonl",
                kind: .claude,
                activityState: .idle)
            state.handleDelta(.terminalReplaced(replacement))
        }

        #expect(state.tabs[worktreeID]?[0].label == nil)
        #expect(state.tabs[worktreeID]?[1].label == "My captain")
    }
}
