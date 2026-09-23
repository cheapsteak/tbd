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
        presentationActivityState: TerminalActivityState? = .idle,
        transport: TerminalTransport = .tmux
    ) -> Terminal {
        Terminal(
            worktreeID: UUID(),
            tmuxWindowID: transport == .tmux ? "@1" : "",
            tmuxPaneID: transport == .tmux ? "%1" : "",
            transcriptPath: transcriptPath,
            kind: kind,
            activityState: activityState,
            presentationActivityState: presentationActivityState,
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
        #expect(ContinueInClaudeMenu.isEnabled(for: terminal(activityState: .working)))
        #expect(!ContinueInClaudeMenu.isEnabled(for: terminal(activityState: .waitingForUser)))
        #expect(!ContinueInClaudeMenu.isEnabled(for: terminal(activityState: .unknown)))
        #expect(!ContinueInClaudeMenu.isEnabled(for: terminal(
            activityState: .idle,
            presentationActivityState: nil)))
    }

    @Test("a rollout task_started observation overrides stale durable idle")
    func transcriptWorkingDisablesStaleRawIdle() {
        let staleDurableIdle = terminal(
            activityState: .idle,
            presentationActivityState: .working)

        #expect(WorktreeRowView.isForegroundWorking(staleDurableIdle))
        #expect(!ContinueInClaudeMenu.isEnabled(for: staleDurableIdle))
    }

    @Test("disabled choices explain that the turn must finish")
    func busyCaption() {
        #expect(ContinueInClaudeMenu.caption(
            for: terminal(
                activityState: .working,
                presentationActivityState: .working)) == ContinueInClaudeMenu.busyCaption)
        #expect(ContinueInClaudeMenu.caption(
            for: terminal(activityState: .waitingForUser)) == ContinueInClaudeMenu.busyCaption)
        #expect(ContinueInClaudeMenu.caption(
            for: terminal(activityState: .unknown)) == ContinueInClaudeMenu.busyCaption)
        #expect(ContinueInClaudeMenu.caption(for: terminal(
            activityState: .idle,
            presentationActivityState: .working)) == ContinueInClaudeMenu.busyCaption)
        #expect(ContinueInClaudeMenu.caption(
            for: terminal(activityState: .working)) == nil)
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
        let layout = LayoutNode.split(
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

    @Test("a pre-commit list cannot undo replacement and a later rollback remains admissible")
    func replacementFencesOverlappingSnapshot() throws {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        let tabID = UUID()
        let source = Terminal(
            id: terminalID,
            worktreeID: worktreeID,
            tmuxWindowID: "@4",
            tmuxPaneID: "%7",
            label: "Codex",
            claudeSessionID: "codex-thread",
            transcriptPath: "/tmp/codex-rollout.jsonl",
            sessionIncarnationID: UUID(),
            kind: .codex,
            activityState: .idle,
            presentationActivityState: .idle)
        let replacement = Terminal(
            id: terminalID,
            worktreeID: worktreeID,
            tmuxWindowID: "@4",
            tmuxPaneID: "%8",
            label: "Claude",
            claudeSessionID: "claude-session",
            profileID: UUID(),
            transcriptPath: "/tmp/claude-session.jsonl",
            sessionIncarnationID: UUID(),
            kind: .claude,
            activityState: .idle)
        state.terminals[worktreeID] = [source]
        state.tabs[worktreeID] = [
            Tab(id: tabID, content: .terminal(terminalID: terminalID), label: "Codex"),
        ]
        let overlappingListGeneration = state.terminalReplacementObservationGeneration

        state.handleDelta(.terminalReplaced(replacement))
        state.adoptTerminalSnapshot(
            [source],
            worktreeID: worktreeID,
            startedAtReplacementGeneration: overlappingListGeneration)

        let committed = try #require(state.terminals[worktreeID]?.first)
        #expect(committed == replacement)
        #expect(state.tabs[worktreeID] == [
            Tab(id: tabID, content: .terminal(terminalID: terminalID), label: nil),
        ])
        #expect(!ContinueInClaudeMenu.isVisible(for: committed))

        var rollback = source
        rollback.sessionIncarnationID = UUID()
        let laterListGeneration = state.terminalReplacementObservationGeneration
        state.adoptTerminalSnapshot(
            [rollback],
            worktreeID: worktreeID,
            startedAtReplacementGeneration: laterListGeneration)

        let restored = try #require(state.terminals[worktreeID]?.first)
        #expect(restored == rollback)
        #expect(ContinueInClaudeMenu.isVisible(for: restored))
        #expect(ContinueInClaudeMenu.isEnabled(for: restored))
    }
}
