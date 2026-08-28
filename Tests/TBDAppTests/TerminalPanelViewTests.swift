import Foundation
import Testing
@testable import TBDApp
import TBDShared

@Suite("Terminal panel close context")
struct TerminalPanelViewTests {
    @Test("generic command failure renders diagnostics guidance without recovery")
    func commandFailureRendersGuidanceWithoutRecovery() {
        let action = TerminalPanelRepresentable.Coordinator.preparationAction(
            for: .failure(.commandFailed(stage: .linkWindow, output: "failed"))
        )

        #expect(action == .showMessage(
            "TBD couldn't attach to this terminal. The terminal was left unchanged. Check diagnostics for details or close the tab."
        ))
    }

    @Test("unresolvable tmux executable names the remedy instead of diagnostics")
    func tmuxExecutableUnavailableRendersLocateGuidance() {
        let action = TerminalPanelRepresentable.Coordinator.preparationAction(
            for: .failure(.tmuxExecutableUnavailable)
        )

        #expect(action == .showMessage(
            "TBD couldn't find tmux — it is not in PATH and no fallback path is saved. Locate the tmux executable in Settings → Terminal, then reopen this terminal."
        ))
        #expect(action != .showMessage(
            TerminalPreparationPresentation.commandFailedMessage
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
    @Test("confirmed grouped viewer attachment, not process spawn, resets the automatic recovery budget")
    func confirmedGroupedViewerAttachmentResetsRecoveryBudget() {
        let state = AppState()
        let terminalID = UUID()
        seedTerminal(terminalID, in: state)
        _ = state.claimAutomaticTerminalRecreation(terminalID: terminalID)
        state.finishTerminalRecreation(terminalID: terminalID)

        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state
        coordinator.panelID = terminalID
        let generation = coordinator.groupedViewerProcessDidStart(processRunning: true)
        #expect(coordinator.beginGroupedViewerAttachmentConfirmation() == generation)

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) ==
            .claimed(attempt: 2))
        state.finishTerminalRecreation(terminalID: terminalID)

        #expect(coordinator.groupedViewerAttachmentProbeDidComplete(
            clientAttached: false,
            processGeneration: generation
        ))
        #expect(coordinator.beginGroupedViewerAttachmentConfirmation() == generation)
        #expect(!coordinator.groupedViewerAttachmentProbeDidComplete(
            clientAttached: true,
            processGeneration: generation
        ))

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) ==
            .claimed(attempt: 1))
    }

    @MainActor
    @Test("failed grouped viewer attachment confirmation does not reset recovery")
    func failedGroupedViewerConfirmationDoesNotResetRecoveryBudget() {
        let state = AppState()
        let terminalID = UUID()
        seedTerminal(terminalID, in: state)
        _ = state.claimAutomaticTerminalRecreation(terminalID: terminalID)
        state.finishTerminalRecreation(terminalID: terminalID)

        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state
        coordinator.panelID = terminalID
        let generation = coordinator.groupedViewerProcessDidStart(processRunning: true)
        #expect(coordinator.beginGroupedViewerAttachmentConfirmation() == generation)
        #expect(coordinator.groupedViewerAttachmentProbeDidComplete(
            clientAttached: false,
            processGeneration: generation
        ))
        #expect(coordinator.beginGroupedViewerAttachmentConfirmation() == generation)
        #expect(!coordinator.groupedViewerAttachmentProbeDidComplete(
            clientAttached: false,
            processGeneration: generation
        ))
        #expect(coordinator.beginGroupedViewerAttachmentConfirmation() == nil)

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) ==
            .claimed(attempt: 2))
    }

    @MainActor
    @Test("a late grouped viewer probe cannot confirm a restarted process")
    func lateGroupedViewerProbeCannotConfirmRestartedProcess() {
        let state = AppState()
        let terminalID = UUID()
        seedTerminal(terminalID, in: state)
        _ = state.claimAutomaticTerminalRecreation(terminalID: terminalID)
        state.finishTerminalRecreation(terminalID: terminalID)

        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state
        coordinator.panelID = terminalID
        let staleGeneration = coordinator.groupedViewerProcessDidStart(processRunning: true)
        #expect(coordinator.beginGroupedViewerAttachmentConfirmation() == staleGeneration)
        coordinator.groupedViewerProcessDidTerminate()
        let liveGeneration = coordinator.groupedViewerProcessDidStart(processRunning: true)

        #expect(!coordinator.groupedViewerAttachmentProbeDidComplete(
            clientAttached: true,
            processGeneration: staleGeneration
        ))

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) ==
            .claimed(attempt: 2))
        state.finishTerminalRecreation(terminalID: terminalID)

        #expect(coordinator.beginGroupedViewerAttachmentConfirmation() == liveGeneration)
        #expect(!coordinator.groupedViewerAttachmentProbeDidComplete(
            clientAttached: true,
            processGeneration: liveGeneration
        ))
        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) ==
            .claimed(attempt: 1))
    }

    @MainActor
    @Test("control-mode live attachment resets the automatic recovery budget")
    func controlModeAttachmentResetsRecoveryBudget() {
        let state = AppState()
        let terminalID = UUID()
        seedTerminal(terminalID, in: state)
        _ = state.claimAutomaticTerminalRecreation(terminalID: terminalID)
        state.finishTerminalRecreation(terminalID: terminalID)

        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state
        coordinator.panelID = terminalID
        coordinator.controlModeViewerDidStart()

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) ==
            .claimed(attempt: 1))
    }

    @Test("budget exhaustion renders stable recovery guidance")
    func budgetExhaustionRendersStableGuidance() {
        #expect(TerminalPanelRepresentable.Coordinator.recoveryMessage(for: .budgetExhausted) ==
            "The terminal window is still unavailable after two automatic recovery attempts. Retry manually or close the tab.")
    }

    @Test("failed automatic recovery renders stable manual retry guidance")
    func failedRecoveryRendersStableGuidance() {
        #expect(TerminalPanelRepresentable.Coordinator.recoveryMessage(for: .failed(attempt: 1)) ==
            "Automatic terminal recovery failed. Retry manually or close the tab.")
    }

    @Test("budget exhaustion presentation exposes manual retry")
    func budgetExhaustionPresentationExposesManualRetry() {
        #expect(TerminalRecoveryPresentation.retryTitle == "Retry")
        #expect(TerminalRecoveryPresentation.exhaustedMessage ==
            "The terminal window is still unavailable after two automatic recovery attempts. Retry manually or close the tab.")
    }

    @MainActor
    @Test("recovery guidance callback carries the actual failed and exhausted messages")
    func recoveryGuidanceCallbackCarriesActualMessage() {
        let coordinator = TerminalPanelRepresentable.Coordinator()
        var messages: [String] = []
        coordinator.onRecoveryGuidance = { messages.append($0) }

        coordinator.recoveryGuidanceDidBecomeAvailable(
            TerminalRecoveryPresentation.failedMessage
        )
        coordinator.recoveryGuidanceDidBecomeAvailable(
            TerminalRecoveryPresentation.exhaustedMessage
        )

        #expect(messages == [
            "Automatic terminal recovery failed. Retry manually or close the tab.",
            "The terminal window is still unavailable after two automatic recovery attempts. Retry manually or close the tab."
        ])
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
    @Test("recovery diagnostic context retains worktree after terminal removal")
    func recoveryDiagnosticContextSurvivesTerminalRemoval() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        seedTerminal(terminalID, in: state, worktreeID: worktreeID)
        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state
        coordinator.panelID = terminalID

        let context = coordinator.recoveryDiagnosticContext()
        state.removeDeletedTerminalFromState(
            terminalID: terminalID,
            worktreeID: worktreeID
        )

        #expect(coordinator.worktreeIDForDiagnostics() == nil)
        #expect(context.terminalID == terminalID)
        #expect(context.worktreeID == worktreeID)
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

    @MainActor
    private func seedTerminal(
        _ terminalID: UUID,
        in state: AppState,
        worktreeID: UUID = UUID()
    ) {
        state.terminals[worktreeID] = [Terminal(
            id: terminalID,
            worktreeID: worktreeID,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: "Shell",
            kind: .shell
        )]
    }
}
