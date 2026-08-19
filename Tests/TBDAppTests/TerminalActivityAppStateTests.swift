import Foundation
import Testing
@testable import TBDApp
import TBDShared

@MainActor
private func interruptedCodexState(
    observedAt: Date = Date(timeIntervalSinceReferenceDate: 20)
) -> (state: AppState, worktreeID: UUID, terminalID: UUID) {
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
                presentationActivityState: .working,
                activityStateSource: .terminalInterrupt,
                activityStateObservedAt: observedAt
            )
        ]
    ]
    return (state, worktreeID, terminalID)
}

private enum PartialActivityProvenance: Sendable {
    case sourceOnly
    case observedAtOnly
}

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
@Test func appState_olderSnapshotDoesNotRollbackCodexInterrupt() {
    let fixture = interruptedCodexState()
    let olderSnapshot = Terminal(
        id: fixture.terminalID,
        worktreeID: fixture.worktreeID,
        tmuxWindowID: "@1",
        tmuxPaneID: "%1",
        label: "Codex",
        kind: .codex,
        activityState: .working,
        presentationActivityState: .working,
        activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent),
        activityStateObservedAt: Date(timeIntervalSinceReferenceDate: 10)
    )

    fixture.state.adoptTerminalSnapshot([olderSnapshot], worktreeID: fixture.worktreeID)

    let terminal = fixture.state.terminals[fixture.worktreeID]![0]
    #expect(terminal.activityState == .idle)
    #expect(terminal.activityStateSource == .terminalInterrupt)
    #expect(terminal.activityStateObservedAt == Date(timeIntervalSinceReferenceDate: 20))
    #expect(!WorktreeRowView.isForegroundWorking(terminal))
}

@MainActor
@Test func appState_olderDeltaDoesNotRollbackCodexInterrupt() {
    let fixture = interruptedCodexState()

    fixture.state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: fixture.terminalID,
        worktreeID: fixture.worktreeID,
        activityState: .working,
        activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent),
        activityStateObservedAt: Date(timeIntervalSinceReferenceDate: 10)
    )))

    let terminal = fixture.state.terminals[fixture.worktreeID]![0]
    #expect(terminal.activityState == .idle)
    #expect(terminal.activityStateSource == .terminalInterrupt)
    #expect(terminal.activityStateObservedAt == Date(timeIntervalSinceReferenceDate: 20))
    #expect(!WorktreeRowView.isForegroundWorking(terminal))
}

@MainActor
@Test func appState_equalTimestampSnapshotDoesNotOverrideCodexInterrupt() {
    let fixture = interruptedCodexState()
    let snapshot = Terminal(
        id: fixture.terminalID,
        worktreeID: fixture.worktreeID,
        tmuxWindowID: "@1",
        tmuxPaneID: "%1",
        label: "Codex",
        kind: .codex,
        activityState: .working,
        presentationActivityState: .working,
        activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent),
        activityStateObservedAt: Date(timeIntervalSinceReferenceDate: 20)
    )

    fixture.state.adoptTerminalSnapshot([snapshot], worktreeID: fixture.worktreeID)

    let terminal = fixture.state.terminals[fixture.worktreeID]![0]
    #expect(terminal.activityState == .idle)
    #expect(terminal.activityStateSource == .terminalInterrupt)
    #expect(terminal.activityStateObservedAt == Date(timeIntervalSinceReferenceDate: 20))
    #expect(!WorktreeRowView.isForegroundWorking(terminal))
}

@MainActor
@Test func appState_equalTimestampDeltaDoesNotOverrideCodexInterrupt() {
    let fixture = interruptedCodexState()

    fixture.state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: fixture.terminalID,
        worktreeID: fixture.worktreeID,
        activityState: .working,
        activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent),
        activityStateObservedAt: Date(timeIntervalSinceReferenceDate: 20)
    )))

    let terminal = fixture.state.terminals[fixture.worktreeID]![0]
    #expect(terminal.activityState == .idle)
    #expect(terminal.activityStateSource == .terminalInterrupt)
    #expect(terminal.activityStateObservedAt == Date(timeIntervalSinceReferenceDate: 20))
    #expect(!WorktreeRowView.isForegroundWorking(terminal))
}

@MainActor
@Test func appState_newerWorkingSnapshotSupersedesCodexInterrupt() {
    let fixture = interruptedCodexState()
    let newerSnapshot = Terminal(
        id: fixture.terminalID,
        worktreeID: fixture.worktreeID,
        tmuxWindowID: "@1",
        tmuxPaneID: "%1",
        label: "Codex",
        kind: .codex,
        activityState: .working,
        presentationActivityState: .working,
        activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent),
        activityStateObservedAt: Date(timeIntervalSinceReferenceDate: 30)
    )

    fixture.state.adoptTerminalSnapshot([newerSnapshot], worktreeID: fixture.worktreeID)

    let terminal = fixture.state.terminals[fixture.worktreeID]![0]
    #expect(terminal.activityState == .working)
    #expect(terminal.activityStateSource == .hookEvent(RPCMethod.terminalActivityEvent))
    #expect(terminal.activityStateObservedAt == Date(timeIntervalSinceReferenceDate: 30))
    #expect(WorktreeRowView.isForegroundWorking(terminal))
}

@MainActor
@Test func appState_newerSessionStartDeltaSupersedesCodexInterrupt() {
    let fixture = interruptedCodexState()

    fixture.state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: fixture.terminalID,
        worktreeID: fixture.worktreeID,
        activityState: .idle,
        activityStateSource: .hookEvent("SessionStart"),
        activityStateObservedAt: Date(timeIntervalSinceReferenceDate: 30)
    )))

    let terminal = fixture.state.terminals[fixture.worktreeID]![0]
    #expect(terminal.activityStateSource == .hookEvent("SessionStart"))
    #expect(terminal.activityStateObservedAt == Date(timeIntervalSinceReferenceDate: 30))
    #expect(terminal.presentationActivityState == .idle)
    #expect(!WorktreeRowView.isForegroundWorking(terminal))
}

@MainActor
@Test func appState_sameValueLegacyIdleDeltaPreservesCodexInterrupt() throws {
    let fixture = interruptedCodexState()
    let delta = try JSONDecoder().decode(
        TerminalActivityDelta.self,
        from: Data(
            #"{"terminalID":"\#(fixture.terminalID.uuidString)","worktreeID":"\#(fixture.worktreeID.uuidString)","activityState":"idle"}"#.utf8
        )
    )

    fixture.state.handleDelta(.terminalActivityUpdated(delta))

    let terminal = fixture.state.terminals[fixture.worktreeID]![0]
    #expect(terminal.activityState == .idle)
    #expect(terminal.activityStateSource == .terminalInterrupt)
    #expect(terminal.activityStateObservedAt == Date(timeIntervalSinceReferenceDate: 20))
    #expect(!WorktreeRowView.isForegroundWorking(terminal))
}

@MainActor
@Test func appState_legacyWorkingDeltaSupersedesInterruptWithoutMixingProvenance() throws {
    let fixture = interruptedCodexState()
    let delta = try JSONDecoder().decode(
        TerminalActivityDelta.self,
        from: Data(
            #"{"terminalID":"\#(fixture.terminalID.uuidString)","worktreeID":"\#(fixture.worktreeID.uuidString)","activityState":"working"}"#.utf8
        )
    )

    fixture.state.handleDelta(.terminalActivityUpdated(delta))

    let terminal = fixture.state.terminals[fixture.worktreeID]![0]
    #expect(terminal.activityState == .working)
    #expect(terminal.activityStateSource == nil)
    #expect(terminal.activityStateObservedAt == nil)
    #expect(WorktreeRowView.isForegroundWorking(terminal))
}

@MainActor
@Test(arguments: [PartialActivityProvenance.sourceOnly, .observedAtOnly])
private func appState_halfProvenanceDeltaClearsBothHalvesWhenApplied(
    partial: PartialActivityProvenance
) {
    let fixture = interruptedCodexState()
    let delta: TerminalActivityDelta
    switch partial {
    case .sourceOnly:
        delta = TerminalActivityDelta(
            terminalID: fixture.terminalID,
            worktreeID: fixture.worktreeID,
            activityState: .working,
            activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent)
        )
    case .observedAtOnly:
        delta = TerminalActivityDelta(
            terminalID: fixture.terminalID,
            worktreeID: fixture.worktreeID,
            activityState: .working,
            activityStateObservedAt: Date(timeIntervalSinceReferenceDate: 30)
        )
    }

    fixture.state.handleDelta(.terminalActivityUpdated(delta))

    let terminal = fixture.state.terminals[fixture.worktreeID]![0]
    #expect(terminal.activityState == .working)
    #expect(terminal.activityStateSource == nil)
    #expect(terminal.activityStateObservedAt == nil)
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
