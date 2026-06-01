import Foundation
import Testing
@testable import TBDApp
import TBDShared

@Suite("Terminal panel close context")
struct TerminalPanelViewTests {
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
}
