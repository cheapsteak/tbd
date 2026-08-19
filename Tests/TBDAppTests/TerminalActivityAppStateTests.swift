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
                activityStateSource: .terminalInterrupt,
                activityStateObservedAt: currentAt,
                activityStateOrderObservedAt: currentAt)
        ]
    ]
    state.terminalPresentationOrderObservedAt[terminalID] = currentAt
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
    #expect(state.terminalPresentationOrderObservedAt[terminalID] == nil)
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
    state.terminalPresentationOrderObservedAt[terminalID] = currentAt
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
    #expect(state.terminalPresentationOrderObservedAt[terminalID] == nil)
    #expect(state.terminalSessionOrderObservedAt[terminalID] == nil)
}

@MainActor
@Test(
    "non-Codex activity deltas retain legacy raw last-arrival behavior",
    arguments: [TerminalKind.claude, .shell]
)
func appState_nonCodexActivityDeltaRetainsLegacyArrivalOrder(kind: TerminalKind) {
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
                kind: kind,
                activityState: .working,
                activityStateSource: .hookEvent("current"),
                activityStateObservedAt: currentAt,
                activityStateOrderObservedAt: currentAt)
        ]
    ]

    state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        activityState: .idle,
        activityStateSource: .terminalInterrupt,
        activityStateObservedAt: Date(timeIntervalSinceReferenceDate: 10),
        activityStateOrderObservedAt: Date(timeIntervalSinceReferenceDate: 10))))

    let adopted = state.terminals[worktreeID]![0]
    #expect(adopted.activityState == .idle)
    #expect(adopted.activityStateSource == .hookEvent("current"))
    #expect(adopted.activityStateObservedAt == currentAt)
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
@Test func appState_sessionStartDeltaAdvancesPresentationOrderPastDelayedList() throws {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let initialAt = Date(timeIntervalSinceReferenceDate: 10)
    let stableAt = Date(timeIntervalSinceReferenceDate: 20)
    let delayedAt = Date(timeIntervalSinceReferenceDate: 25)
    let sessionStartAt = Date(timeIntervalSinceReferenceDate: 30)
    let newerAt = Date(timeIntervalSinceReferenceDate: 40)
    let original = Terminal(
        id: terminalID,
        worktreeID: worktreeID,
        tmuxWindowID: "@1",
        tmuxPaneID: "%1",
        label: "Codex",
        kind: .codex,
        activityState: .idle,
        presentationActivityState: .working,
        presentationActivityObservedAt: initialAt,
        activityStateSource: .hookEvent("Stop"),
        activityStateObservedAt: initialAt,
        activityStateOrderObservedAt: initialAt)
    state.terminals = [worktreeID: [original]]

    var stable = original
    stable.presentationActivityObservedAt = stableAt
    state.adoptTerminalSnapshot([stable], worktreeID: worktreeID)
    #expect(state.terminalPresentationOrderObservedAt[terminalID] == stableAt)

    state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        activityState: .idle,
        activityStateSource: .hookEvent("SessionStart"),
        activityStateObservedAt: sessionStartAt,
        activityStateOrderObservedAt: sessionStartAt)))
    #expect(state.terminals[worktreeID]?.first?.presentationActivityState == .idle)
    #expect(state.terminalPresentationOrderObservedAt[terminalID] == sessionStartAt)

    var delayedWorking = try #require(state.terminals[worktreeID]?.first)
    delayedWorking.presentationActivityState = .working
    delayedWorking.presentationActivityObservedAt = delayedAt
    state.adoptTerminalSnapshot([delayedWorking], worktreeID: worktreeID)
    #expect(state.terminals[worktreeID]?.first?.presentationActivityState == .idle)

    var newerWorking = try #require(state.terminals[worktreeID]?.first)
    newerWorking.presentationActivityState = .working
    newerWorking.presentationActivityObservedAt = newerAt
    state.adoptTerminalSnapshot([newerWorking], worktreeID: worktreeID)
    #expect(state.terminals[worktreeID]?.first?.presentationActivityState == .working)
    #expect(state.terminalPresentationOrderObservedAt[terminalID] == newerAt)
}

@MainActor
@Test func appState_delayedSessionStartCannotRegressHiddenUnknownPresentationOrder() throws {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let oldAt = Date(timeIntervalSinceReferenceDate: 20)
    let sessionStartAt = Date(timeIntervalSinceReferenceDate: 30)
    let delayedWorkingAt = Date(timeIntervalSinceReferenceDate: 35)
    let unknownAt = Date(timeIntervalSinceReferenceDate: 40)
    let newerSessionStartAt = Date(timeIntervalSinceReferenceDate: 50)
    let original = Terminal(
        id: terminalID,
        worktreeID: worktreeID,
        tmuxWindowID: "@1",
        tmuxPaneID: "%1",
        label: "Codex",
        claudeSessionID: "session",
        transcriptPath: "/tmp/session.jsonl",
        kind: .codex,
        activityState: .working,
        presentationActivityState: .working,
        presentationActivityObservedAt: oldAt,
        activityStateSource: .hookEvent("UserPromptSubmit"),
        activityStateObservedAt: oldAt,
        activityStateOrderObservedAt: oldAt)
    state.terminals = [worktreeID: [original]]

    state.handleDelta(.terminalSessionUpdated(TerminalSessionDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        sessionID: "session",
        transcriptPath: "/tmp/session.jsonl",
        sessionOrderObservedAt: sessionStartAt)))

    var authoritativeUnknown = try #require(state.terminals[worktreeID]?.first)
    authoritativeUnknown.activityState = .idle
    authoritativeUnknown.activityStateSource = .hookEvent("SessionStart")
    authoritativeUnknown.activityStateObservedAt = sessionStartAt
    authoritativeUnknown.activityStateOrderObservedAt = sessionStartAt
    authoritativeUnknown.presentationActivityState = nil
    authoritativeUnknown.presentationActivityObservedAt = unknownAt
    state.adoptTerminalSnapshot([authoritativeUnknown], worktreeID: worktreeID)

    #expect(state.terminals[worktreeID]?.first?.presentationActivityState == nil)
    #expect(state.terminals[worktreeID]?.first?.presentationActivityObservedAt == nil)
    #expect(state.terminalPresentationOrderObservedAt[terminalID] == unknownAt)

    state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        activityState: .idle,
        activityStateSource: .hookEvent("SessionStart"),
        activityStateObservedAt: sessionStartAt,
        activityStateOrderObservedAt: sessionStartAt)))

    var delayedWorking = try #require(state.terminals[worktreeID]?.first)
    delayedWorking.presentationActivityState = .working
    delayedWorking.presentationActivityObservedAt = delayedWorkingAt
    state.adoptTerminalSnapshot([delayedWorking], worktreeID: worktreeID)

    #expect(state.terminals[worktreeID]?.first?.presentationActivityState == nil)
    #expect(state.terminalPresentationOrderObservedAt[terminalID] == unknownAt)

    state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        activityState: .idle,
        activityStateSource: .hookEvent("SessionStart"),
        activityStateObservedAt: unknownAt,
        activityStateOrderObservedAt: unknownAt)))
    #expect(state.terminals[worktreeID]?.first?.presentationActivityState == .idle)
    #expect(state.terminalPresentationOrderObservedAt[terminalID] == unknownAt)

    state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        activityState: .idle,
        activityStateSource: .hookEvent("SessionStart"),
        activityStateObservedAt: newerSessionStartAt,
        activityStateOrderObservedAt: newerSessionStartAt)))
    #expect(state.terminals[worktreeID]?.first?.presentationActivityState == .idle)
    #expect(state.terminalPresentationOrderObservedAt[terminalID] == newerSessionStartAt)
}

@MainActor
@Test func appState_samePathSessionBoundaryRejectsPreBoundaryPresentation() throws {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let oldAt = Date(timeIntervalSinceReferenceDate: 20)
    let sessionStartAt = Date(timeIntervalSinceReferenceDate: 30)
    let stalePresentationAt = Date(timeIntervalSinceReferenceDate: 40)
    let preBoundary = Terminal(
        id: terminalID,
        worktreeID: worktreeID,
        tmuxWindowID: "@1",
        tmuxPaneID: "%1",
        label: "Codex",
        claudeSessionID: "session",
        transcriptPath: "/tmp/session.jsonl",
        kind: .codex,
        activityState: .working,
        presentationActivityState: .working,
        presentationActivityObservedAt: stalePresentationAt,
        activityStateSource: .hookEvent("UserPromptSubmit"),
        activityStateObservedAt: oldAt,
        activityStateOrderObservedAt: oldAt)
    state.terminals = [worktreeID: [preBoundary]]

    state.handleDelta(.terminalSessionUpdated(TerminalSessionDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        sessionID: "session",
        transcriptPath: "/tmp/session.jsonl",
        sessionOrderObservedAt: sessionStartAt)))
    state.adoptTerminalSnapshot([preBoundary], worktreeID: worktreeID)

    var terminal = try #require(state.terminals[worktreeID]?.first)
    #expect(terminal.presentationActivityState == nil)
    #expect(terminal.presentationActivityObservedAt == nil)
    #expect(state.terminalPresentationOrderObservedAt[terminalID] == sessionStartAt)

    state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        activityState: .idle,
        activityStateSource: .hookEvent("SessionStart"),
        activityStateObservedAt: sessionStartAt,
        activityStateOrderObservedAt: sessionStartAt)))

    terminal = try #require(state.terminals[worktreeID]?.first)
    #expect(terminal.presentationActivityState == .idle)
    #expect(!WorktreeRowView.isForegroundWorking(terminal))
}

@MainActor
@Test func appState_sessionIdentityRolloverResetsPresentationOrder() {
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
                presentationActivityObservedAt:
                    Date(timeIntervalSinceReferenceDate: 40))
        ]
    ]
    state.terminalPresentationOrderObservedAt[terminalID] =
        Date(timeIntervalSinceReferenceDate: 20)
    state.terminalSessionOrderObservedAt[terminalID] =
        Date(timeIntervalSinceReferenceDate: 20)
    let sessionStartAt = Date(timeIntervalSinceReferenceDate: 30)

    state.handleDelta(.terminalSessionUpdated(TerminalSessionDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        sessionID: "new-session",
        transcriptPath: "/tmp/new-session.jsonl",
        sessionOrderObservedAt: sessionStartAt)))

    #expect(state.terminalPresentationOrderObservedAt[terminalID] == sessionStartAt)
    #expect(state.terminalSessionOrderObservedAt[terminalID] == sessionStartAt)
    #expect(state.terminals[worktreeID]?.first?.presentationActivityState == nil)
    #expect(state.terminals[worktreeID]?.first?.presentationActivityObservedAt == nil)

    // The activity delta belongs to the new identity. Its older wall-clock
    // stamp must not be compared with presentation evidence from the old one.
    state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        activityState: .idle,
        activityStateSource: .hookEvent("SessionStart"),
        activityStateObservedAt: sessionStartAt,
        activityStateOrderObservedAt: sessionStartAt)))
    #expect(state.terminals[worktreeID]?.first?.presentationActivityState == .idle)
    #expect(state.terminals[worktreeID]?.first?.presentationActivityObservedAt == sessionStartAt)
    #expect(state.terminalPresentationOrderObservedAt[terminalID] == sessionStartAt)
}

@MainActor
@Test func appState_legacyNilPathSessionRolloverClearsOldPresentation() {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let oldPath = "/tmp/existing-session.jsonl"
    state.terminals = [
        worktreeID: [
            Terminal(
                id: terminalID,
                worktreeID: worktreeID,
                tmuxWindowID: "@1",
                tmuxPaneID: "%1",
                label: "Codex",
                claudeSessionID: "old-session",
                transcriptPath: oldPath,
                kind: .codex,
                presentationActivityState: .working,
                presentationActivityObservedAt:
                    Date(timeIntervalSinceReferenceDate: 40))
        ]
    ]
    state.terminalPresentationOrderObservedAt[terminalID] =
        Date(timeIntervalSinceReferenceDate: 40)

    state.handleDelta(.terminalSessionUpdated(TerminalSessionDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        sessionID: "new-session",
        transcriptPath: nil)))

    let terminal = state.terminals[worktreeID]?.first
    #expect(terminal?.transcriptPath == oldPath)
    #expect(terminal?.presentationActivityState == nil)
    #expect(terminal?.presentationActivityObservedAt == nil)
    #expect(state.terminalPresentationOrderObservedAt[terminalID] == nil)
    #expect(state.terminalSessionOrderObservedAt[terminalID] == nil)
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
        presentationActivityState: .working,
        presentationActivityObservedAt: oldAt,
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
        activityStateSource: .hookEvent("SessionStart"),
        activityStateObservedAt: sessionStartAt,
        activityStateOrderObservedAt: sessionStartAt)))

    state.adoptTerminalSnapshot([oldSnapshot], worktreeID: worktreeID)

    let terminal = state.terminals[worktreeID]?.first
    #expect(terminal?.claudeSessionID == "new-session")
    #expect(terminal?.transcriptPath == "/tmp/new-session.jsonl")
    #expect(terminal?.activityStateSource == .hookEvent("SessionStart"))
    #expect(terminal?.presentationActivityState == .idle)
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
        presentationActivityState: .working,
        presentationActivityObservedAt: oldAt,
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
    #expect(terminal?.presentationActivityState == nil)
    #expect(state.terminalSessionOrderObservedAt[terminalID] == sessionStartAt)

    state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        activityState: .idle,
        activityStateSource: .hookEvent("SessionStart"),
        activityStateObservedAt: sessionStartAt,
        activityStateOrderObservedAt: sessionStartAt)))
    terminal = state.terminals[worktreeID]?.first
    #expect(terminal?.activityStateSource == .hookEvent("SessionStart"))
    #expect(terminal?.presentationActivityState == .idle)
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
@Test func appState_sameSessionIdentityPreservesPresentationOrder() {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let observedAt = Date(timeIntervalSinceReferenceDate: 20)
    state.terminals = [
        worktreeID: [
            Terminal(
                id: terminalID,
                worktreeID: worktreeID,
                tmuxWindowID: "@1",
                tmuxPaneID: "%1",
                label: "Codex",
                claudeSessionID: "same-session",
                transcriptPath: "/tmp/same-session.jsonl",
                kind: .codex)
        ]
    ]
    state.terminalPresentationOrderObservedAt[terminalID] = observedAt

    state.handleDelta(.terminalSessionUpdated(TerminalSessionDelta(
        terminalID: terminalID,
        worktreeID: worktreeID,
        sessionID: "same-session",
        transcriptPath: "/tmp/same-session.jsonl")))

    #expect(state.terminalPresentationOrderObservedAt[terminalID] == observedAt)
}

@MainActor
@Test func appState_terminalRemovalClearsPresentationOrder() {
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
    state.terminalPresentationOrderObservedAt[terminalID] =
        Date(timeIntervalSinceReferenceDate: 20)

    state.removeDeletedTerminalFromState(
        terminalID: terminalID,
        worktreeID: worktreeID)

    #expect(state.terminalPresentationOrderObservedAt[terminalID] == nil)
}

@MainActor
@Test func appState_recreatedTerminalReplacesPresentationOrder() {
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
    state.terminalPresentationOrderObservedAt[terminalID] =
        Date(timeIntervalSinceReferenceDate: 20)
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
        presentationActivityState: .idle,
        presentationActivityObservedAt: replacementAt,
        activityStateSource: .hookEvent("SessionStart"),
        activityStateObservedAt: replacementAt,
        activityStateOrderObservedAt: replacementAt)

    state.adoptRecreatedTerminal(replacement)

    #expect(state.terminalPresentationOrderObservedAt[terminalID] == replacementAt)
    #expect(state.terminalSessionOrderObservedAt[terminalID] == replacementAt)
}

@MainActor
@Test func appState_createdTerminalReplacementResetsPresentationOrder() {
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
    state.terminalPresentationOrderObservedAt[terminalID] =
        Date(timeIntervalSinceReferenceDate: 20)
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

    #expect(state.terminalPresentationOrderObservedAt[terminalID] == nil)
    #expect(state.terminalSessionOrderObservedAt[terminalID] == nil)
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
@Test(
    "Claude Ctrl+C and Esc retain legacy raw-idle interrupt behavior",
    arguments: [false, true]
)
func appState_claudeInterruptRetainsLegacyRawIdle(viaEscape: Bool) {
    let state = AppState()
    let worktreeID = UUID()
    let terminalID = UUID()
    let observedAt = Date(timeIntervalSinceReferenceDate: 20)
    state.terminals = [
        worktreeID: [
            Terminal(
                id: terminalID,
                worktreeID: worktreeID,
                tmuxWindowID: "@1",
                tmuxPaneID: "%1",
                label: "Claude",
                kind: .claude,
                activityState: .working,
                activityStateSource: .hookEvent("UserPromptSubmit"),
                activityStateObservedAt: observedAt
            )
        ]
    ]

    state.handleTerminalInterrupt(terminalID: terminalID, viaEscape: viaEscape)

    #expect(state.terminals[worktreeID]?[0].activityState == .idle)
    #expect(state.terminals[worktreeID]?[0].activityStateSource == .hookEvent("UserPromptSubmit"))
    #expect(state.terminals[worktreeID]?[0].activityStateObservedAt == observedAt)
}

@MainActor
@Test func appState_escDoesNotInterruptCodex() {
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
                presentationActivityState: .working)
        ]
    ]

    state.handleTerminalInterrupt(terminalID: terminalID, viaEscape: true)

    #expect(state.terminals[worktreeID]?[0].activityState == .working)
    #expect(state.terminals[worktreeID]?[0].presentationActivityState == .working)
}
