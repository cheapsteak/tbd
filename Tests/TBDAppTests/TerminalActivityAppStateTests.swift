import Foundation
import Testing
@testable import TBDApp
import TBDShared

@MainActor
private func idleCodexState(
    observedAt: Date = Date(timeIntervalSinceReferenceDate: 20)
) -> (state: AppState, worktreeID: UUID, terminalID: UUID) {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    state.terminals = [
        worktreeID: [
            TBDShared.Terminal(
                id: terminalID,
                worktreeID: worktreeID,
                tmuxWindowID: "@1",
                tmuxPaneID: "%1",
                label: "Codex",
                kind: .codex,
                activityState: .idle,
                activityStateSource: .programStatus,
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
@Test(
    "non-Codex snapshots retain legacy arrival-order replacement",
    arguments: [TerminalKind.claude, .shell]
)
func appState_nonCodexSnapshotRetainsLegacyArrivalOrder(kind: TerminalKind) {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let currentAt = Date(timeIntervalSinceReferenceDate: 20)
    let incomingAt = Date(timeIntervalSinceReferenceDate: 10)
    state.terminals = [
        worktreeID: [
            Terminal(
                id: terminalID,
                worktreeID: worktreeID,
                tmuxWindowID: "@1",
                tmuxPaneID: "%1",
                label: kind == .claude ? "Claude" : "shell",
                claudeSessionID: "current-session",
                transcriptPath: "/tmp/current.jsonl",
                sessionOrderObservedAt: currentAt,
                kind: kind,
                activityState: .idle,
                activityStateSource: .programStatus,
                activityStateObservedAt: currentAt,
                activityStateOrderObservedAt: currentAt)
        ]
    ]
    state.terminalSessionOrderObservedAt[terminalID] = currentAt
    let snapshot = Terminal(
        id: terminalID,
        worktreeID: worktreeID,
        tmuxWindowID: "@1",
        tmuxPaneID: "%1",
        label: kind == .claude ? "Claude" : "shell",
        claudeSessionID: "arrived-session",
        transcriptPath: "/tmp/arrived.jsonl",
        sessionOrderObservedAt: incomingAt,
        kind: kind,
        activityState: .working,
        activityStateSource: .hookEvent("legacy"),
        activityStateObservedAt: incomingAt,
        activityStateOrderObservedAt: incomingAt)

    state.adoptTerminalSnapshot([snapshot], worktreeID: worktreeID)

    let adopted = state.terminals[worktreeID]![0]
    #expect(adopted.claudeSessionID == "arrived-session")
    #expect(adopted.transcriptPath == "/tmp/arrived.jsonl")
    #expect(adopted.activityState == .working)
    #expect(adopted.activityStateSource == .hookEvent("legacy"))
    #expect(state.terminalSessionOrderObservedAt[terminalID] == nil)
}

@MainActor
@Test(
    "non-Codex session deltas retain legacy last-arrival identity",
    arguments: [TerminalKind.claude, .shell]
)
func appState_nonCodexSessionDeltaRetainsLegacyArrivalOrder(kind: TerminalKind) {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let currentAt = Date(timeIntervalSinceReferenceDate: 20)
    state.terminals = [
        worktreeID: [
            Terminal(
                id: terminalID,
                worktreeID: worktreeID,
                tmuxWindowID: "@1",
                tmuxPaneID: "%1",
                label: kind == .claude ? "Claude" : "shell",
                claudeSessionID: "current-session",
                transcriptPath: "/tmp/current.jsonl",
                sessionOrderObservedAt: currentAt,
                kind: kind)
        ]
    ]
    state.terminalSessionOrderObservedAt[terminalID] = currentAt

    state.handleDelta(.terminalSessionUpdated(TerminalSessionDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        sessionID: "arrived-session",
        transcriptPath: "/tmp/arrived.jsonl",
        sessionOrderObservedAt: Date(timeIntervalSinceReferenceDate: 10))))

    let adopted = state.terminals[worktreeID]![0]
    #expect(adopted.claudeSessionID == "arrived-session")
    #expect(adopted.transcriptPath == "/tmp/arrived.jsonl")
    #expect(state.terminalSessionOrderObservedAt[terminalID] == nil)
}

/// The program status store has two ingest paths — the daemon's own reader
/// and the reports the app forwards — whose broadcasts can arrive out of
/// commit order. Every row, not only a Codex one, orders activity deltas by
/// their stamp: two delivered out of order leave the newer value standing.
@MainActor
@Test(
    "activity deltas delivered out of order leave the newer value on every row",
    arguments: [TerminalKind.claude, .shell, .codex]
)
func appState_outOfOrderActivityDeltasLeaveTheNewerValue(kind: TerminalKind) {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let older = Date(timeIntervalSinceReferenceDate: 10)
    let newer = Date(timeIntervalSinceReferenceDate: 20)
    state.terminals = [
        worktreeID: [
            TBDShared.Terminal(
                id: terminalID,
                worktreeID: worktreeID,
                tmuxWindowID: "",
                tmuxPaneID: "",
                kind: kind,
                transport: .holder)
        ]
    ]

    state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        activityState: .working,
        activityStateSource: .programStatus,
        activityStateObservedAt: newer,
        activityStateOrderObservedAt: newer)))
    state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        activityState: .waitingForUser,
        activityStateSource: .programStatus,
        activityStateObservedAt: older,
        activityStateOrderObservedAt: older)))

    let adopted = state.terminals[worktreeID]![0]
    #expect(adopted.activityState == .working)
    #expect(adopted.activityStateSource == .programStatus)
    #expect(adopted.activityStateObservedAt == newer)
    #expect(adopted.activityStateOrderObservedAt == newer)
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
@Test func appState_olderSnapshotDoesNotRollbackNewerCodexActivity() {
    let fixture = idleCodexState()
    let olderSnapshot = Terminal(
        id: fixture.terminalID,
        worktreeID: fixture.worktreeID,
        tmuxWindowID: "@1",
        tmuxPaneID: "%1",
        label: "Codex",
        kind: .codex,
        activityState: .working,
        activityStateSource: .programStatus,
        activityStateObservedAt: Date(timeIntervalSinceReferenceDate: 10)
    )

    fixture.state.adoptTerminalSnapshot([olderSnapshot], worktreeID: fixture.worktreeID)

    let terminal = fixture.state.terminals[fixture.worktreeID]![0]
    #expect(terminal.activityState == .idle)
    #expect(terminal.activityStateSource == .programStatus)
    #expect(terminal.activityStateObservedAt == Date(timeIntervalSinceReferenceDate: 20))
    #expect(!WorktreeRowView.isForegroundWorking(terminal))
}

@MainActor
@Test func appState_staleOldIdentityListCannotRollbackAcceptedSessionStart() {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let oldAt = Date(timeIntervalSinceReferenceDate: 20)
    let sessionStartAt = Date(timeIntervalSinceReferenceDate: 30)
    let oldSnapshot = Terminal(
        id: terminalID,
        worktreeID: worktreeID,
        tmuxWindowID: "@1",
        tmuxPaneID: "%1",
        label: "Codex",
        claudeSessionID: "old-session",
        transcriptPath: "/tmp/old-session.jsonl",
        kind: .codex,
        activityState: .working,
        activityStateSource: .hookEvent("UserPromptSubmit"),
        activityStateObservedAt: oldAt,
        activityStateOrderObservedAt: oldAt)
    state.terminals = [worktreeID: [oldSnapshot]]
    state.adoptTerminalSnapshot([oldSnapshot], worktreeID: worktreeID)

    state.handleDelta(.terminalSessionUpdated(TerminalSessionDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        sessionID: "new-session",
        transcriptPath: "/tmp/new-session.jsonl",
        sessionOrderObservedAt: sessionStartAt)))
    state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        activityState: .idle,
        activityStateSource: .programStatus,
        activityStateObservedAt: sessionStartAt,
        activityStateOrderObservedAt: sessionStartAt)))

    state.adoptTerminalSnapshot([oldSnapshot], worktreeID: worktreeID)

    let terminal = state.terminals[worktreeID]?.first
    #expect(terminal?.claudeSessionID == "new-session")
    #expect(terminal?.transcriptPath == "/tmp/new-session.jsonl")
    #expect(terminal?.activityState == .idle)
    #expect(terminal?.activityStateSource == .programStatus)
}

@MainActor
@Test func appState_sessionDeltaFencesStaleListBeforeActivityDelta() {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let oldAt = Date(timeIntervalSinceReferenceDate: 20)
    let sessionStartAt = Date(timeIntervalSinceReferenceDate: 30)
    let oldSnapshot = Terminal(
        id: terminalID,
        worktreeID: worktreeID,
        tmuxWindowID: "@1",
        tmuxPaneID: "%1",
        label: "Codex",
        claudeSessionID: "old-session",
        transcriptPath: "/tmp/old-session.jsonl",
        kind: .codex,
        activityState: .working,
        activityStateSource: .hookEvent("UserPromptSubmit"),
        activityStateObservedAt: oldAt,
        activityStateOrderObservedAt: oldAt)
    state.terminals = [worktreeID: [oldSnapshot]]

    state.handleDelta(.terminalSessionUpdated(TerminalSessionDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        sessionID: "new-session",
        transcriptPath: "/tmp/new-session.jsonl",
        sessionOrderObservedAt: sessionStartAt)))
    state.adoptTerminalSnapshot([oldSnapshot], worktreeID: worktreeID)

    var terminal = state.terminals[worktreeID]?.first
    #expect(terminal?.claudeSessionID == "new-session")
    #expect(terminal?.transcriptPath == "/tmp/new-session.jsonl")
    #expect(terminal?.sessionOrderObservedAt == sessionStartAt)
    #expect(state.terminalSessionOrderObservedAt[terminalID] == sessionStartAt)

    state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        activityState: .idle,
        activityStateSource: .programStatus,
        activityStateObservedAt: sessionStartAt,
        activityStateOrderObservedAt: sessionStartAt)))
    terminal = state.terminals[worktreeID]?.first
    #expect(terminal?.activityState == .idle)
    #expect(terminal?.activityStateSource == .programStatus)
}

@MainActor
@Test func appState_persistedSessionOrderFencesStaleSnapshotIdentity() throws {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let oldActivityAt = Date(timeIntervalSinceReferenceDate: 20)
    let staleSessionAt = Date(timeIntervalSinceReferenceDate: 25)
    let currentSessionAt = Date(timeIntervalSinceReferenceDate: 30)
    let misleadingNewerActivityAt = Date(timeIntervalSinceReferenceDate: 40)
    let current = Terminal(
        id: terminalID,
        worktreeID: worktreeID,
        tmuxWindowID: "@1",
        tmuxPaneID: "%1",
        label: "Codex",
        claudeSessionID: "current-session",
        transcriptPath: "/tmp/current-session.jsonl",
        sessionOrderObservedAt: currentSessionAt,
        kind: .codex,
        activityState: .idle,
        activityStateSource: .hookEvent("Stop"),
        activityStateObservedAt: oldActivityAt,
        activityStateOrderObservedAt: oldActivityAt)
    state.terminals = [worktreeID: [current]]

    var stale = current
    stale.claudeSessionID = "stale-session"
    stale.transcriptPath = "/tmp/stale-session.jsonl"
    stale.sessionOrderObservedAt = staleSessionAt
    stale.activityStateOrderObservedAt = misleadingNewerActivityAt
    state.adoptTerminalSnapshot([stale], worktreeID: worktreeID)

    let terminal = state.terminals[worktreeID]?.first
    #expect(terminal?.claudeSessionID == "current-session")
    #expect(terminal?.transcriptPath == "/tmp/current-session.jsonl")
    #expect(terminal?.sessionOrderObservedAt == currentSessionAt)
    #expect(state.terminalSessionOrderObservedAt[terminalID] == currentSessionAt)

    var sameIdentityStale = try #require(terminal)
    sameIdentityStale.sessionOrderObservedAt = staleSessionAt
    sameIdentityStale.activityStateOrderObservedAt = misleadingNewerActivityAt
    state.adoptTerminalSnapshot([sameIdentityStale], worktreeID: worktreeID)

    #expect(state.terminals[worktreeID]?.first?.sessionOrderObservedAt == currentSessionAt)
    #expect(state.terminalSessionOrderObservedAt[terminalID] == currentSessionAt)
}

@MainActor
@Test func appState_terminalRemovalClearsSessionOrder() {
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
                kind: .codex)
        ]
    ]
    state.terminalSessionOrderObservedAt[terminalID] =
        Date(timeIntervalSinceReferenceDate: 20)

    state.removeDeletedTerminalFromState(
        terminalID: terminalID,
        worktreeID: worktreeID)

    #expect(state.terminalSessionOrderObservedAt[terminalID] == nil)
}

@MainActor
@Test func appState_recreatedTerminalReplacesSessionOrder() {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let replacementAt = Date(timeIntervalSinceReferenceDate: 30)
    state.terminals = [
        worktreeID: [
            Terminal(
                id: terminalID,
                worktreeID: worktreeID,
                tmuxWindowID: "@1",
                tmuxPaneID: "%1",
                label: "Codex",
                claudeSessionID: "old-session",
                transcriptPath: "/tmp/old-session.jsonl",
                kind: .codex)
        ]
    ]
    state.terminalSessionOrderObservedAt[terminalID] =
        Date(timeIntervalSinceReferenceDate: 20)
    let replacement = Terminal(
        id: terminalID,
        worktreeID: worktreeID,
        tmuxWindowID: "@2",
        tmuxPaneID: "%2",
        label: "Codex",
        claudeSessionID: "new-session",
        transcriptPath: "/tmp/new-session.jsonl",
        kind: .codex,
        activityStateSource: .programStatus,
        activityStateObservedAt: replacementAt,
        activityStateOrderObservedAt: replacementAt)

    state.adoptRecreatedTerminal(replacement)

    #expect(state.terminalSessionOrderObservedAt[terminalID] == replacementAt)
}

@MainActor
@Test func appState_createdTerminalReplacementResetsSessionOrder() {
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
                claudeSessionID: "old-session",
                transcriptPath: "/tmp/old-session.jsonl",
                kind: .codex)
        ]
    ]
    state.terminalSessionOrderObservedAt[terminalID] =
        Date(timeIntervalSinceReferenceDate: 20)
    let replacement = Terminal(
        id: terminalID,
        worktreeID: worktreeID,
        tmuxWindowID: "@2",
        tmuxPaneID: "%2",
        label: "Codex",
        kind: .codex)

    state.mergeCreatedTerminal(replacement)

    #expect(state.terminalSessionOrderObservedAt[terminalID] == nil)
}

@MainActor
@Test func appState_olderDeltaDoesNotRollbackNewerCodexActivity() {
    let fixture = idleCodexState()

    fixture.state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: fixture.terminalID,
        worktreeID: fixture.worktreeID,
        activityState: .working,
        activityStateSource: .programStatus,
        activityStateObservedAt: Date(timeIntervalSinceReferenceDate: 10)
    )))

    let terminal = fixture.state.terminals[fixture.worktreeID]![0]
    #expect(terminal.activityState == .idle)
    #expect(terminal.activityStateSource == .programStatus)
    #expect(terminal.activityStateObservedAt == Date(timeIntervalSinceReferenceDate: 20))
    #expect(!WorktreeRowView.isForegroundWorking(terminal))
}

@MainActor
@Test func appState_newerSameStateDeltaAdvancesOrderWithoutRewritingProvenance() {
    let fixture = idleCodexState()
    let newerOrder = Date(timeIntervalSinceReferenceDate: 30)

    fixture.state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: fixture.terminalID,
        worktreeID: fixture.worktreeID,
        activityState: .idle,
        activityStateSource: .programStatus,
        activityStateObservedAt: newerOrder,
        activityStateOrderObservedAt: newerOrder
    )))

    let terminal = fixture.state.terminals[fixture.worktreeID]![0]
    #expect(terminal.activityState == .idle)
    #expect(terminal.activityStateSource == .programStatus)
    #expect(terminal.activityStateObservedAt == Date(timeIntervalSinceReferenceDate: 20))
    #expect(terminal.activityStateOrderObservedAt == newerOrder)
}

@MainActor
@Test func appState_newerSameStateSnapshotAdvancesOrderWithoutRewritingProvenance() throws {
    let idleAt = Date(timeIntervalSinceReferenceDate: 20)
    let fixture = idleCodexState(observedAt: idleAt)
    let newerOrder = idleAt.addingTimeInterval(1)
    let snapshot = Terminal(
        id: fixture.terminalID,
        worktreeID: fixture.worktreeID,
        tmuxWindowID: "@1",
        tmuxPaneID: "%1",
        label: "Codex",
        kind: .codex,
        activityState: .idle,
        activityStateSource: .programStatus,
        activityStateObservedAt: newerOrder,
        activityStateOrderObservedAt: newerOrder
    )

    fixture.state.adoptTerminalSnapshot([snapshot], worktreeID: fixture.worktreeID)

    let terminal = try #require(fixture.state.terminals[fixture.worktreeID]?.first)
    #expect(terminal.activityState == .idle)
    #expect(terminal.activityStateSource == .programStatus)
    #expect(terminal.activityStateObservedAt == idleAt)
    #expect(terminal.activityStateOrderObservedAt == newerOrder)
    #expect(!WorktreeRowView.isForegroundWorking(terminal))
}

@MainActor
@Test func appState_activityDeltaUsesOrderingWatermarkInsteadOfTransitionTime() throws {
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
                activityStateSource: .hookEvent("Stop"),
                activityStateObservedAt: Date(timeIntervalSinceReferenceDate: 20)
            )
        ]
    ]
    let delta = try JSONDecoder().decode(
        TerminalActivityDelta.self,
        from: Data(
            """
            {"terminalID":"\(terminalID.uuidString)","worktreeID":"\(worktreeID.uuidString)","activityState":"working","activityStateSource":{"kind":"hook","detail":"UserPromptSubmit"},"activityStateObservedAt":10,"activityStateOrderObservedAt":30}
            """.utf8
        )
    )

    state.handleDelta(.terminalActivityUpdated(delta))

    let terminal = state.terminals[worktreeID]![0]
    #expect(terminal.activityState == .working)
    #expect(terminal.activityStateSource == .hookEvent("UserPromptSubmit"))
    #expect(terminal.activityStateObservedAt == Date(timeIntervalSinceReferenceDate: 10))
}

@MainActor
@Test func appState_equalTimestampWorkingDeltaDoesNotOverrideIdle() {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let instant = Date(timeIntervalSinceReferenceDate: 20)
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
                activityStateSource: .hookEvent("Stop"),
                activityStateObservedAt: instant,
                activityStateOrderObservedAt: instant
            )
        ]
    ]

    state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        activityState: .working,
        activityStateSource: .hookEvent("UserPromptSubmit"),
        activityStateObservedAt: instant,
        activityStateOrderObservedAt: instant
    )))

    let terminal = state.terminals[worktreeID]![0]
    #expect(terminal.activityState == .idle)
    #expect(terminal.activityStateSource == .hookEvent("Stop"))
}

@MainActor
@Test func appState_equalTimestampWorkingSnapshotDoesNotOverrideIdle() {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let instant = Date(timeIntervalSinceReferenceDate: 20)
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
                activityStateSource: .hookEvent("Stop"),
                activityStateObservedAt: instant,
                activityStateOrderObservedAt: instant
            )
        ]
    ]
    let snapshot = Terminal(
        id: terminalID,
        worktreeID: worktreeID,
        tmuxWindowID: "@1",
        tmuxPaneID: "%1",
        label: "Codex",
        kind: .codex,
        activityState: .working,
        activityStateSource: .hookEvent("UserPromptSubmit"),
        activityStateObservedAt: instant,
        activityStateOrderObservedAt: instant
    )

    state.adoptTerminalSnapshot([snapshot], worktreeID: worktreeID)

    let terminal = state.terminals[worktreeID]![0]
    #expect(terminal.activityState == .idle)
    #expect(terminal.activityStateSource == .hookEvent("Stop"))
}

@MainActor
@Test func appState_equalTimestampIdleDeltaDoesNotOverrideWaitingForUser() {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let instant = Date(timeIntervalSinceReferenceDate: 20)
    state.terminals = [
        worktreeID: [
            Terminal(
                id: terminalID,
                worktreeID: worktreeID,
                tmuxWindowID: "@1",
                tmuxPaneID: "%1",
                label: "Codex",
                kind: .codex,
                activityState: .waitingForUser,
                activityStateSource: .hookEvent("PermissionRequest"),
                activityStateObservedAt: instant,
                activityStateOrderObservedAt: instant
            )
        ]
    ]

    state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        activityState: .idle,
        activityStateSource: .hookEvent("Stop"),
        activityStateObservedAt: instant,
        activityStateOrderObservedAt: instant
    )))

    let terminal = state.terminals[worktreeID]![0]
    #expect(terminal.activityState == .waitingForUser)
    #expect(terminal.activityStateSource == .hookEvent("PermissionRequest"))
}

@MainActor
@Test func appState_newerWorkingSnapshotSupersedesCodexIdle() {
    let fixture = idleCodexState()
    let newerSnapshot = Terminal(
        id: fixture.terminalID,
        worktreeID: fixture.worktreeID,
        tmuxWindowID: "@1",
        tmuxPaneID: "%1",
        label: "Codex",
        kind: .codex,
        activityState: .working,
        activityStateSource: .programStatus,
        activityStateObservedAt: Date(timeIntervalSinceReferenceDate: 30)
    )

    fixture.state.adoptTerminalSnapshot([newerSnapshot], worktreeID: fixture.worktreeID)

    let terminal = fixture.state.terminals[fixture.worktreeID]![0]
    #expect(terminal.activityState == .working)
    #expect(terminal.activityStateSource == .programStatus)
    #expect(terminal.activityStateObservedAt == Date(timeIntervalSinceReferenceDate: 30))
    #expect(WorktreeRowView.isForegroundWorking(terminal))
}

@MainActor
@Test func appState_sameValueLegacyIdleDeltaPreservesCurrentProvenance() throws {
    let fixture = idleCodexState()
    let delta = try JSONDecoder().decode(
        TerminalActivityDelta.self,
        from: Data(
            #"{"terminalID":"\#(fixture.terminalID.uuidString)","worktreeID":"\#(fixture.worktreeID.uuidString)","activityState":"idle"}"#.utf8
        )
    )

    fixture.state.handleDelta(.terminalActivityUpdated(delta))

    let terminal = fixture.state.terminals[fixture.worktreeID]![0]
    #expect(terminal.activityState == .idle)
    #expect(terminal.activityStateSource == .programStatus)
    #expect(terminal.activityStateObservedAt == Date(timeIntervalSinceReferenceDate: 20))
    #expect(!WorktreeRowView.isForegroundWorking(terminal))
}

@MainActor
@Test func appState_legacyWorkingDeltaSupersedesIdleWithoutMixingProvenance() throws {
    let fixture = idleCodexState()
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
    let fixture = idleCodexState()
    let delta: TerminalActivityDelta
    switch partial {
    case .sourceOnly:
        delta = TerminalActivityDelta(
            terminalID: fixture.terminalID,
            worktreeID: fixture.worktreeID,
            activityState: .working,
            activityStateSource: .programStatus
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
@Test func appState_completeWorkingDeltaSupersedesHalfProvenanceIdle() throws {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let delta = try JSONDecoder().decode(
        TerminalActivityDelta.self,
        from: Data(
            #"{"terminalID":"\#(terminalID.uuidString)","worktreeID":"\#(worktreeID.uuidString)","activityState":"working","activityStateSource":{"kind":"program-status"},"activityStateObservedAt":0}"#.utf8
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
                activityStateSource: .programStatus
            )
        ]
    ]

    state.handleDelta(.terminalActivityUpdated(delta))

    #expect(state.terminals[worktreeID]?[0].activityState == .working)
    #expect(state.terminals[worktreeID]?[0].activityStateSource == .programStatus)
    #expect(state.terminals[worktreeID]?[0].activityStateObservedAt == Date(timeIntervalSinceReferenceDate: 0))
    #expect(WorktreeRowView.isForegroundWorking(state.terminals[worktreeID]![0]))
}
