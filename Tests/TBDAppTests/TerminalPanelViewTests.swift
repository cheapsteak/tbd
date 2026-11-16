import Foundation
import Testing
@testable import TBDApp
import TBDShared

@Suite("Terminal panel coordinator")
struct TerminalPanelViewTests {
    // MARK: - Transport lookup
    //
    // `panelTransport()` gates the holder-only behaviors — mouse reporting,
    // the program status probe, an engine switch — so it answers `.holder`
    // only for a row AppState has loaded as one.

    @MainActor
    @Test("a holder-backed terminal resolves as holder")
    func holderTerminalResolvesAsHolder() {
        let state = AppState()
        let terminalID = UUID()
        seedTerminal(terminalID, in: state, transport: .holder)

        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state
        coordinator.panelID = terminalID

        #expect(coordinator.panelTransport() == .holder)
    }

    @MainActor
    @Test("a tmux-backed terminal resolves as tmux")
    func tmuxTerminalResolvesAsTmux() {
        let state = AppState()
        let terminalID = UUID()
        seedTerminal(terminalID, in: state, transport: .tmux)

        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state
        coordinator.panelID = terminalID

        #expect(coordinator.panelTransport() == .tmux)
    }

    @MainActor
    @Test("an unresolvable terminal fails closed, not as holder")
    func unresolvableTerminalFailsClosed() {
        // AppState has not loaded this terminal (or it was removed). The
        // lookup must not invent a holder row and switch on behaviors only a
        // holder session may have.
        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = AppState()
        coordinator.panelID = UUID()

        #expect(coordinator.panelTransport() == .tmux)
        #expect(!TerminalPanelRepresentable.reportsMouseToApps(transport: coordinator.panelTransport()))
    }

    // MARK: - The daemon's recreate refusal

    /// The leftover notice shows the daemon's own sentence under it, so the
    /// refusal carries it verbatim whatever its code.
    @Test("a refusal carries the daemon's sentence, whatever its code")
    func aRefusalCarriesTheDaemonsSentence() {
        let coded = TerminalRecreationRefusal.from(DaemonClientError.rpcError(
            "anything at all", code: RPCErrorCode.terminalOnTmux.rawValue))
        #expect(coded == TerminalRecreationRefusal(message: "anything at all"))

        let uncoded = TerminalRecreationRefusal.from(DaemonClientError.rpcError(
            "Worktree not found for terminal: acme", code: nil))
        #expect(uncoded == TerminalRecreationRefusal(message: "Worktree not found for terminal: acme"))
    }

    @Test("a failure the daemon did not write is no refusal")
    func aFailureTheDaemonDidNotWriteIsNoRefusal() {
        #expect(TerminalRecreationRefusal.from(DaemonClientError.daemonNotRunning) == nil,
                "a failure the daemon did not write was shown as its refusal")
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
    private func seedTerminal(
        _ terminalID: UUID,
        in state: AppState,
        worktreeID: UUID = UUID(),
        transport: TerminalTransport = .tmux
    ) {
        // A holder row carries EMPTY tmux coordinates by construction — the v1
        // schema's NOT NULL columns cannot be relaxed — so it must be
        // discriminated by `transport` alone, never by those strings.
        let isHolder = transport == .holder
        state.terminals[worktreeID] = [Terminal(
            id: terminalID,
            worktreeID: worktreeID,
            tmuxWindowID: isHolder ? "" : "@1",
            tmuxPaneID: isHolder ? "" : "%1",
            label: "Shell",
            kind: .shell,
            transport: transport
        )]
    }
}
