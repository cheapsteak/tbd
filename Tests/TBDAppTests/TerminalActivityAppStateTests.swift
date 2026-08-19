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

private func decodedCodexSnapshot(
    terminalID: UUID,
    worktreeID: UUID,
    presentationState: String?,
    presentationObservedAt: Double?
) throws -> Terminal {
    let presentation = presentationState.map {
        ",\"presentationActivityState\":\"\($0)\""
    } ?? ""
    let presentationTime = presentationObservedAt.map {
        ",\"presentationActivityObservedAt\":\($0)"
    } ?? ""
    return try JSONDecoder().decode(
        Terminal.self,
        from: Data(
            """
            {"id":"\(terminalID.uuidString)","worktreeID":"\(worktreeID.uuidString)","tmuxWindowID":"@1","tmuxPaneID":"%1","label":"Codex","createdAt":0,"kind":"codex","activityState":"idle"\(presentation)\(presentationTime),"activityStateSource":{"kind":"hook","detail":"Stop"},"activityStateObservedAt":5}
            """.utf8
        )
    )
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
@Test func appState_staleRawSnapshotStillAdoptsFreshTranscriptPresentation() {
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
                activityStateSource: .hookEvent("Stop"),
                activityStateObservedAt: Date(timeIntervalSinceReferenceDate: 20)
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
        presentationActivityState: .idle,
        activityStateSource: .hookEvent(RPCMethod.terminalActivityEvent),
        activityStateObservedAt: Date(timeIntervalSinceReferenceDate: 10)
    )

    state.adoptTerminalSnapshot([snapshot], worktreeID: worktreeID)

    let terminal = state.terminals[worktreeID]![0]
    #expect(terminal.activityState == .idle)
    #expect(terminal.activityStateSource == .hookEvent("Stop"))
    #expect(terminal.activityStateObservedAt == Date(timeIntervalSinceReferenceDate: 20))
    #expect(terminal.presentationActivityState == .idle)
    #expect(!WorktreeRowView.isForegroundWorking(terminal))
}

@MainActor
@Test func appState_reversedTranscriptSnapshotsKeepNewerIdlePresentation() throws {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let newerIdle = try decodedCodexSnapshot(
        terminalID: terminalID,
        worktreeID: worktreeID,
        presentationState: "idle",
        presentationObservedAt: 20
    )
    let olderWorking = try decodedCodexSnapshot(
        terminalID: terminalID,
        worktreeID: worktreeID,
        presentationState: "working",
        presentationObservedAt: 10
    )

    state.adoptTerminalSnapshot([newerIdle], worktreeID: worktreeID)
    state.adoptTerminalSnapshot([olderWorking], worktreeID: worktreeID)

    let terminal = state.terminals[worktreeID]![0]
    #expect(terminal.presentationActivityState == .idle)
    #expect(!WorktreeRowView.isForegroundWorking(terminal))
}

@MainActor
@Test func appState_equalTranscriptTimestampPrefersIdleOverWorking() throws {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let idle = try decodedCodexSnapshot(
        terminalID: terminalID,
        worktreeID: worktreeID,
        presentationState: "idle",
        presentationObservedAt: 20
    )
    let working = try decodedCodexSnapshot(
        terminalID: terminalID,
        worktreeID: worktreeID,
        presentationState: "working",
        presentationObservedAt: 20
    )

    state.adoptTerminalSnapshot([idle], worktreeID: worktreeID)
    state.adoptTerminalSnapshot([working], worktreeID: worktreeID)

    #expect(state.terminals[worktreeID]?[0].presentationActivityState == .idle)
}

@MainActor
@Test func appState_reversedTranscriptSnapshotsKeepNewerUnknownPresentation() throws {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let newerUnknown = try decodedCodexSnapshot(
        terminalID: terminalID,
        worktreeID: worktreeID,
        presentationState: nil,
        presentationObservedAt: 20
    )
    let olderWorking = try decodedCodexSnapshot(
        terminalID: terminalID,
        worktreeID: worktreeID,
        presentationState: "working",
        presentationObservedAt: 10
    )

    state.adoptTerminalSnapshot([newerUnknown], worktreeID: worktreeID)
    state.adoptTerminalSnapshot([olderWorking], worktreeID: worktreeID)

    #expect(state.terminals[worktreeID]?[0].presentationActivityState == nil)
}

@MainActor
@Test func appState_stablePresentationAdvancesOrderWithoutChangingTerminal() throws {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let firstAt = Date(timeIntervalSinceReferenceDate: 10)
    let stableAt = Date(timeIntervalSinceReferenceDate: 20)
    let newerAt = Date(timeIntervalSinceReferenceDate: 30)
    let unavailableAt = Date(timeIntervalSinceReferenceDate: 40)
    let original = Terminal(
        id: terminalID,
        worktreeID: worktreeID,
        tmuxWindowID: "@1",
        tmuxPaneID: "%1",
        label: "Codex",
        kind: .codex,
        activityState: .idle,
        presentationActivityState: .working,
        presentationActivityObservedAt: firstAt,
        activityStateSource: .hookEvent("Stop"),
        activityStateObservedAt: firstAt,
        activityStateOrderObservedAt: firstAt)
    state.terminals = [worktreeID: [original]]

    var stable = original
    stable.presentationActivityObservedAt = stableAt
    state.adoptTerminalSnapshot([stable], worktreeID: worktreeID)
    #expect(try #require(state.terminals[worktreeID]?.first) == original)

    // The non-published watermark still advances, so an overlapping older
    // response with a different value cannot roll presentation backward.
    var delayedIdle = original
    delayedIdle.presentationActivityState = .idle
    delayedIdle.presentationActivityObservedAt = firstAt.addingTimeInterval(5)
    state.adoptTerminalSnapshot([delayedIdle], worktreeID: worktreeID)
    #expect(try #require(state.terminals[worktreeID]?.first) == original)

    var newerIdle = original
    newerIdle.presentationActivityState = .idle
    newerIdle.presentationActivityObservedAt = newerAt
    state.adoptTerminalSnapshot([newerIdle], worktreeID: worktreeID)
    #expect(state.terminals[worktreeID]?.first?.presentationActivityState == .idle)
    #expect(state.terminals[worktreeID]?.first?.presentationActivityObservedAt == newerAt)

    var authoritativeUnknown = newerIdle
    authoritativeUnknown.presentationActivityState = nil
    authoritativeUnknown.presentationActivityObservedAt = unavailableAt
    state.adoptTerminalSnapshot([authoritativeUnknown], worktreeID: worktreeID)
    #expect(state.terminals[worktreeID]?.first?.presentationActivityState == nil)
    #expect(state.terminals[worktreeID]?.first?.presentationActivityObservedAt == unavailableAt)
}

@MainActor
@Test func appState_legacyTranscriptSnapshotsRemainArrivalOrdered() throws {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let idle = try decodedCodexSnapshot(
        terminalID: terminalID,
        worktreeID: worktreeID,
        presentationState: "idle",
        presentationObservedAt: nil
    )
    let working = try decodedCodexSnapshot(
        terminalID: terminalID,
        worktreeID: worktreeID,
        presentationState: "working",
        presentationObservedAt: nil
    )

    state.adoptTerminalSnapshot([idle], worktreeID: worktreeID)
    state.adoptTerminalSnapshot([working], worktreeID: worktreeID)

    #expect(state.terminals[worktreeID]?[0].presentationActivityState == .working)
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
@Test func appState_newerSameStateHookDeltaAdvancesOrderWithoutErasingInterrupt() {
    let fixture = interruptedCodexState()
    let newerOrder = Date(timeIntervalSinceReferenceDate: 30)

    fixture.state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: fixture.terminalID,
        worktreeID: fixture.worktreeID,
        activityState: .idle,
        activityStateSource: .hookEvent("Stop"),
        activityStateObservedAt: newerOrder,
        activityStateOrderObservedAt: newerOrder
    )))

    let terminal = fixture.state.terminals[fixture.worktreeID]![0]
    #expect(terminal.activityState == .idle)
    #expect(terminal.activityStateSource == .terminalInterrupt)
    #expect(terminal.activityStateObservedAt == Date(timeIntervalSinceReferenceDate: 20))
    #expect(terminal.activityStateOrderObservedAt == newerOrder)
}

@MainActor
@Test func appState_bestEffortInterruptSurvivesNewerSameStateHookSnapshot() throws {
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
                presentationActivityState: .working,
                activityStateSource: .hookEvent("UserPromptSubmit"),
                activityStateObservedAt: Date(timeIntervalSinceReferenceDate: 10)
            )
        ]
    ]

    state.handleTerminalInterrupt(terminalID: terminalID)
    let interrupted = try #require(state.terminals[worktreeID]?.first)
    let interruptedAt = try #require(interrupted.activityStateObservedAt)
    let newerOrder = interruptedAt.addingTimeInterval(1)
    let snapshot = Terminal(
        id: terminalID,
        worktreeID: worktreeID,
        tmuxWindowID: "@1",
        tmuxPaneID: "%1",
        label: "Codex",
        kind: .codex,
        activityState: .idle,
        presentationActivityState: .idle,
        activityStateSource: .hookEvent("Stop"),
        activityStateObservedAt: newerOrder,
        activityStateOrderObservedAt: newerOrder
    )

    state.adoptTerminalSnapshot([snapshot], worktreeID: worktreeID)

    let terminal = try #require(state.terminals[worktreeID]?.first)
    #expect(terminal.activityState == .idle)
    #expect(terminal.activityStateSource == .terminalInterrupt)
    #expect(terminal.activityStateObservedAt == interruptedAt)
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
@Test func appState_newerInterruptDeltaReplacesGenericSameStateFact() {
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
    let interruptAt = Date(timeIntervalSinceReferenceDate: 30)

    state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        activityState: .idle,
        activityStateSource: .terminalInterrupt,
        activityStateObservedAt: interruptAt,
        activityStateOrderObservedAt: interruptAt
    )))

    let terminal = state.terminals[worktreeID]![0]
    #expect(terminal.activityStateSource == .terminalInterrupt)
    #expect(terminal.activityStateObservedAt == interruptAt)
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
@Test func appState_olderSessionStartDoesNotClearNewerTranscriptWorkingPresentation() {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let presentationAt = Date(timeIntervalSinceReferenceDate: 40)
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
                presentationActivityObservedAt: presentationAt,
                activityStateSource: .hookEvent("Stop"),
                activityStateObservedAt: Date(timeIntervalSinceReferenceDate: 20)
            )
        ]
    ]
    let sessionStartAt = Date(timeIntervalSinceReferenceDate: 30)

    state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        activityState: .idle,
        activityStateSource: .hookEvent("SessionStart"),
        activityStateObservedAt: sessionStartAt,
        activityStateOrderObservedAt: sessionStartAt
    )))

    let terminal = state.terminals[worktreeID]![0]
    #expect(terminal.activityStateSource == .hookEvent("SessionStart"))
    #expect(terminal.presentationActivityState == .working)
    #expect(terminal.presentationActivityObservedAt == presentationAt)
}

@MainActor
@Test func appState_timestampedPathRolloverUnknownClearsPriorWorkingInsteadOfCachingIt() {
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
                kind: .codex,
                presentationActivityState: .working,
                presentationActivityObservedAt: Date(timeIntervalSinceReferenceDate: 20)
            )
        ]
    ]
    let unavailableAt = Date(timeIntervalSinceReferenceDate: 30)
    let snapshot = Terminal(
        id: terminalID,
        worktreeID: worktreeID,
        tmuxWindowID: "@1",
        tmuxPaneID: "%1",
        label: "Codex",
        claudeSessionID: "current-session",
        transcriptPath: "/tmp/current-session.jsonl",
        kind: .codex,
        presentationActivityState: nil,
        presentationActivityObservedAt: unavailableAt
    )

    state.adoptTerminalSnapshot([snapshot], worktreeID: worktreeID)

    let terminal = state.terminals[worktreeID]![0]
    #expect(terminal.claudeSessionID == "current-session")
    #expect(terminal.transcriptPath == "/tmp/current-session.jsonl")
    #expect(terminal.presentationActivityState == nil)
    #expect(terminal.presentationActivityObservedAt == unavailableAt)
    #expect(!WorktreeRowView.isForegroundWorking(terminal))
}

@MainActor
@Test func appState_legacyPathRolloverDoesNotCarryPriorWorkingPresentation() {
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
                kind: .codex,
                presentationActivityState: .working,
                presentationActivityObservedAt: Date(timeIntervalSinceReferenceDate: 20))
        ]
    ]
    let rollover = Terminal(
        id: terminalID,
        worktreeID: worktreeID,
        tmuxWindowID: "@1",
        tmuxPaneID: "%1",
        label: "Codex",
        claudeSessionID: "current-session",
        transcriptPath: "/tmp/current-session.jsonl",
        kind: .codex,
        presentationActivityState: nil,
        presentationActivityObservedAt: nil)

    state.adoptTerminalSnapshot([rollover], worktreeID: worktreeID)

    let terminal = state.terminals[worktreeID]![0]
    #expect(terminal.claudeSessionID == "current-session")
    #expect(terminal.presentationActivityState == nil)
    #expect(terminal.presentationActivityObservedAt == nil)
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
