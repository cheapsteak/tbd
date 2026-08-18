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
@Test func appState_sessionStartDeltaClearsCodexPresentationActivityImmediately() {
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
                activityState: .working,
                presentationActivityState: .working
            )
        ]
    ]

    state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        activityState: .idle,
        activityStateSource: .hookEvent("SessionStart"),
        activityStateObservedAt: Date(timeIntervalSinceReferenceDate: 1)
    )))

    let terminal = state.terminals[worktreeID]![0]
    #expect(terminal.presentationActivityState == .idle)
    #expect(!WorktreeRowView.isForegroundWorking(terminal))
}

@MainActor
@Test func appState_genericIdleHookPreservesCodexTranscriptWorkingActivity() {
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
                activityState: .working,
                presentationActivityState: .working
            )
        ]
    ]

    state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        activityState: .idle,
        activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent),
        activityStateObservedAt: Date(timeIntervalSinceReferenceDate: 1)
    )))

    let terminal = state.terminals[worktreeID]![0]
    #expect(terminal.presentationActivityState == .working)
    #expect(WorktreeRowView.isForegroundWorking(terminal))
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
                activityState: .working,
                presentationActivityState: .working
            )
        ]
    ]

    state.handleTerminalInterrupt(terminalID: terminalID)

    #expect(state.terminals[worktreeID]?[0].activityState == .idle)
    #expect(state.terminals[worktreeID]?[0].activityStateSource?.kind == "user-action")
    #expect(state.terminals[worktreeID]?[0].activityStateSource?.detail == "terminal-interrupt")
    #expect(!WorktreeRowView.isForegroundWorking(state.terminals[worktreeID]![0]))
}

@MainActor
@Test func appState_interruptRecordsProvenanceWhenCodexIsAlreadyRawIdle() {
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
                activityState: .idle,
                presentationActivityState: .working
            )
        ]
    ]

    state.handleTerminalInterrupt(terminalID: terminalID)

    #expect(state.terminals[worktreeID]?[0].activityStateSource?.kind == "user-action")
    #expect(state.terminals[worktreeID]?[0].activityStateSource?.detail == "terminal-interrupt")
    #expect(!WorktreeRowView.isForegroundWorking(state.terminals[worktreeID]![0]))
}

@MainActor
@Test func appState_workingHookDeltaSupersedesCodexInterrupt() throws {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let interruptSource = try JSONDecoder().decode(
        FactSource.self,
        from: Data(#"{"kind":"user-action","detail":"terminal-interrupt"}"#.utf8)
    )
    let delta = try JSONDecoder().decode(
        TerminalActivityDelta.self,
        from: Data(
            #"{"terminalID":"\#(terminalID.uuidString)","worktreeID":"\#(worktreeID.uuidString)","activityState":"working","activityStateSource":{"kind":"hook","detail":"terminal.activityEvent"},"activityStateObservedAt":0}"#.utf8
        )
    )
    state.terminals = [
        worktreeID: [
            Terminal(
                id: terminalID,
                worktreeID: worktreeID,
                tmuxWindowID: "@1",
                tmuxPaneID: "%1",
                label: "Codex",
                kind: .codex,
                activityState: .idle,
                presentationActivityState: .working,
                activityStateSource: interruptSource
            )
        ]
    ]

    state.handleDelta(.terminalActivityUpdated(delta))

    #expect(state.terminals[worktreeID]?[0].activityState == .working)
    #expect(state.terminals[worktreeID]?[0].activityStateSource == .hookEvent(RPCMethod.terminalActivityEvent))
    #expect(state.terminals[worktreeID]?[0].activityStateObservedAt == Date(timeIntervalSinceReferenceDate: 0))
    #expect(WorktreeRowView.isForegroundWorking(state.terminals[worktreeID]![0]))
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
