import Foundation
import Testing
@testable import TBDApp
import TBDShared

@Suite("Terminal panel close context")
struct TerminalPanelViewTests {
    @Test("executable unavailable renders guidance without recovery")
    func executableUnavailableRendersGuidanceWithoutRecovery() {
        let action = TerminalPanelRepresentable.Coordinator.preparationAction(
            for: .failure(.executableUnavailable)
        )

        #expect(action == .showMessage(
            "tmux is not available on TBD's PATH. Run scripts/restart.sh from a shell where tmux is available."
        ))
    }

    @Test("generic command failure renders diagnostics guidance without recovery")
    func commandFailureRendersGuidanceWithoutRecovery() {
        let action = TerminalPanelRepresentable.Coordinator.preparationAction(
            for: .failure(.commandFailed(stage: .linkWindow, output: "failed"))
        )

        #expect(action == .showMessage(
            "TBD couldn't attach to this terminal. The terminal was left unchanged. Check diagnostics and retry."
        ))
    }

    @Test("confirmed missing window requests automatic recovery")
    func confirmedMissingWindowRequestsRecovery() {
        let action = TerminalPanelRepresentable.Coordinator.preparationAction(
            for: .failure(.windowMissing(failedStage: .selectWindow))
        )

        #expect(action == .requestAutomaticRecovery(failedStage: .selectWindow))
    }

    @Test("prepared session starts the viewer")
    func preparedSessionStartsViewer() {
        let prepared = TmuxPreparedSession(
            executablePath: "/opt/local/bin/tmux",
            arguments: ["-u", "attach"]
        )

        #expect(TerminalPanelRepresentable.Coordinator.preparationAction(for: .success(prepared)) ==
            .startViewer(prepared))
    }

    @MainActor
    @Test("only a running viewer process resets the automatic recovery budget")
    func onlyRunningViewerProcessResetsRecoveryBudget() {
        let state = AppState()
        let terminalID = UUID()
        _ = state.claimAutomaticTerminalRecreation(terminalID: terminalID)
        state.finishTerminalRecreation(terminalID: terminalID)

        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state
        coordinator.panelID = terminalID
        coordinator.viewerProcessDidStart(processRunning: false)

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) ==
            .claimed(automaticAttempt: 2))
        state.finishTerminalRecreation(terminalID: terminalID)

        coordinator.viewerProcessDidStart(processRunning: true)

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) ==
            .claimed(automaticAttempt: 1))
    }

    @Test("budget exhaustion renders stable recovery guidance")
    func budgetExhaustionRendersStableGuidance() {
        #expect(TerminalPanelRepresentable.Coordinator.recoveryMessage(for: .budgetExhausted) ==
            "The terminal window is still unavailable after two automatic recovery attempts. Retry manually or close the tab.")
    }

    @MainActor
    @Test("stable preparation message is fed once per coordinator")
    func stablePreparationMessageIsFedOnce() {
        let coordinator = TerminalPanelRepresentable.Coordinator()
        let message = "stable failure"

        #expect(coordinator.shouldFeedPreparationMessage(message))
        #expect(!coordinator.shouldFeedPreparationMessage(message))
    }

    @MainActor
    @Test("diagnostic context resolves the terminal worktree")
    func diagnosticContextResolvesTerminalWorktree() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals[worktreeID] = [
            Terminal(
                id: terminalID,
                worktreeID: worktreeID,
                tmuxWindowID: "@1",
                tmuxPaneID: "%1",
                label: "Shell",
                kind: .shell
            )
        ]

        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state
        coordinator.panelID = terminalID

        #expect(coordinator.worktreeIDForDiagnostics() == worktreeID)
    }

    @MainActor
    @Test("syncTabCloseContext refreshes coordinator and app state registration")
    func syncTabCloseContextRefreshesRegistration() {
        let state = AppState()
        let terminalID = UUID()
        let first = TabCloseContext(worktreeID: UUID(), tabID: UUID())
        let second = TabCloseContext(worktreeID: UUID(), tabID: UUID())
        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state

        coordinator.syncTabCloseContext(first, for: terminalID)
        #expect(coordinator.tabCloseContext == first)
        #expect(state.terminalTabCloseContexts[terminalID] == first)

        coordinator.syncTabCloseContext(second, for: terminalID)
        #expect(coordinator.tabCloseContext == second)
        #expect(state.terminalTabCloseContexts[terminalID] == second)

        let noContext: TabCloseContext? = nil
        coordinator.syncTabCloseContext(noContext, for: terminalID)
        #expect(coordinator.tabCloseContext == nil)
        #expect(state.terminalTabCloseContexts[terminalID] == nil)
    }

    @MainActor
    @Test("outgoing ctrl-c clears codex activity")
    func outgoingCtrlCClearsCodexActivity() async {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals = [
            worktreeID: [
                Terminal(
                    id: terminalID,
                    worktreeID: worktreeID,
                    tmuxWindowID: "@1",
                    tmuxPaneID: "%1",
                    label: "Codex",
                    kind: .codex,
                    activityState: .working
                )
            ]
        ]

        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state
        coordinator.panelID = terminalID

        coordinator.handleOutgoingInput([0x03])
        await Task.yield()

        #expect(state.terminals[worktreeID]?[0].activityState == .idle)
    }

    @MainActor
    @Test("non-interrupt input leaves codex activity unchanged")
    func nonInterruptInputLeavesActivityUnchanged() async {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals = [
            worktreeID: [
                Terminal(
                    id: terminalID,
                    worktreeID: worktreeID,
                    tmuxWindowID: "@1",
                    tmuxPaneID: "%1",
                    label: "Codex",
                    kind: .codex,
                    activityState: .working
                )
            ]
        ]

        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state
        coordinator.panelID = terminalID

        coordinator.handleOutgoingInput([UInt8]("hello".utf8)[0...])
        await Task.yield()

        #expect(state.terminals[worktreeID]?[0].activityState == .working)
    }

    @MainActor
    @Test("outgoing esc clears claude activity")
    func outgoingEscClearsClaudeActivity() async {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals = [
            worktreeID: [
                Terminal(
                    id: terminalID,
                    worktreeID: worktreeID,
                    tmuxWindowID: "@1",
                    tmuxPaneID: "%1",
                    label: "Claude",
                    kind: .claude,
                    activityState: .working
                )
            ]
        ]

        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state
        coordinator.panelID = terminalID

        coordinator.handleOutgoingInput([0x1b])
        await Task.yield()

        #expect(state.terminals[worktreeID]?[0].activityState == .idle)
    }

    @MainActor
    @Test("outgoing ctrl-c clears claude activity")
    func outgoingCtrlCClearsClaudeActivity() async {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals = [
            worktreeID: [
                Terminal(
                    id: terminalID,
                    worktreeID: worktreeID,
                    tmuxWindowID: "@1",
                    tmuxPaneID: "%1",
                    label: "Claude",
                    kind: .claude,
                    activityState: .working
                )
            ]
        ]

        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state
        coordinator.panelID = terminalID

        coordinator.handleOutgoingInput([0x03])
        await Task.yield()

        #expect(state.terminals[worktreeID]?[0].activityState == .idle)
    }

    @MainActor
    @Test("multi-byte esc sequence leaves claude activity unchanged")
    func multiByteEscSequenceLeavesClaudeActivityUnchanged() async {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals = [
            worktreeID: [
                Terminal(
                    id: terminalID,
                    worktreeID: worktreeID,
                    tmuxWindowID: "@1",
                    tmuxPaneID: "%1",
                    label: "Claude",
                    kind: .claude,
                    activityState: .working
                )
            ]
        ]

        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state
        coordinator.panelID = terminalID

        // Up arrow: ESC [ A — a multi-byte escape sequence, not a halt.
        coordinator.handleOutgoingInput([0x1b, 0x5b, 0x41])
        await Task.yield()

        #expect(state.terminals[worktreeID]?[0].activityState == .working)
    }

    @MainActor
    @Test("outgoing esc leaves codex activity unchanged")
    func outgoingEscLeavesCodexActivityUnchanged() async {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals = [
            worktreeID: [
                Terminal(
                    id: terminalID,
                    worktreeID: worktreeID,
                    tmuxWindowID: "@1",
                    tmuxPaneID: "%1",
                    label: "Codex",
                    kind: .codex,
                    activityState: .working
                )
            ]
        ]

        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state
        coordinator.panelID = terminalID

        coordinator.handleOutgoingInput([0x1b])
        await Task.yield()

        #expect(state.terminals[worktreeID]?[0].activityState == .working)
    }
}
