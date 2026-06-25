import Foundation
import Testing
@testable import TBDApp
import TBDShared

@MainActor
@Test func appState_handlesTerminalActivityUpdatedDeltaInPlace() {
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
                kind: .codex
            )
        ]
    ]

    state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        activityState: .working
    )))

    #expect(state.terminals[worktreeID]?[0].activityState == .working)
}

@MainActor
@Test func appState_interruptClearsCodexActivityImmediately() {
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

    state.handleTerminalInterrupt(terminalID: terminalID)

    #expect(state.terminals[worktreeID]?[0].activityState == .idle)
}

@MainActor
@Test func appState_interruptDoesNotTouchShellTerminals() {
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
                label: "shell",
                kind: .shell,
                activityState: .working
            )
        ]
    ]

    state.handleTerminalInterrupt(terminalID: terminalID)

    #expect(state.terminals[worktreeID]?[0].activityState == .working)
}

@MainActor
@Test func appState_escInterruptClearsClaudeActivityImmediately() {
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

    state.handleTerminalInterrupt(terminalID: terminalID, viaEscape: true)

    #expect(state.terminals[worktreeID]?[0].activityState == .idle)
}
