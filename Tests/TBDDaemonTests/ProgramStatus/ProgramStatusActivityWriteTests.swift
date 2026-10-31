import Testing
import Foundation
import os
import TBDShared
@testable import TBDDaemonLib

/// `TerminalStore.applyProgramStatusActivity`: the one writer the program
/// status store uses, and the guards it runs inside its own transaction.
@Suite struct ProgramStatusActivityWriteTests {
    private let t0 = Date(timeIntervalSince1970: 5_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private struct Fixture {
        let db: TBDDatabase
        let terminal: Terminal
        let incarnationID: UUID
        let profileID: UUID
    }

    private func makeFixture() async throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/psw-repo-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/psw-wt-\(UUID().uuidString)", tmuxServer: "tbd-psw")
        let incarnationID = UUID()
        let profileID = UUID()
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            profileID: profileID, kind: .claude, transport: .holder,
            sessionIncarnationID: incarnationID)
        return Fixture(db: db, terminal: terminal, incarnationID: incarnationID, profileID: profileID)
    }

    @discardableResult
    private func apply(
        _ fixture: Fixture, _ state: TerminalActivityState, at seconds: TimeInterval,
        reason: AwaitingInputReason? = nil, scope: ProgramStatusWriteScope? = nil
    ) async throws -> ProgramStatusActivityWrite? {
        try await fixture.db.terminals.applyProgramStatusActivity(
            id: fixture.terminal.id, scope: scope ?? .incarnation(fixture.incarnationID),
            activityState: state, awaitingInputReason: reason, observedAt: at(seconds))
    }

    private func row(_ fixture: Fixture) async throws -> Terminal {
        try #require(try await fixture.db.terminals.get(id: fixture.terminal.id))
    }

    private let permissionReason = AwaitingInputReason(
        message: "", programStatusBlock: ProgramStatusBlock(kind: .permission, taskID: nil))

    @Test func writesStateSourceStampAndReason() async throws {
        let fixture = try await makeFixture()

        let waiting = try #require(
            try await apply(fixture, .waitingForUser, at: 1, reason: permissionReason))
        #expect(waiting.worktreeID == fixture.terminal.worktreeID)
        #expect(waiting.previousActivityState == .unknown)
        #expect(waiting.stateChanged && waiting.reasonChanged)
        var stored = try await row(fixture)
        #expect(stored.activityState == .waitingForUser)
        #expect(stored.activityStateSource == .programStatus)
        #expect(stored.activityStateObservedAt == at(1))
        #expect(stored.activityStateOrderObservedAt == at(1))
        #expect(stored.awaitingInputReason == permissionReason)
        #expect(stored.awaitingInputObservedAt == at(1))

        // Moving on retracts the reason with the state it described.
        let working = try #require(try await apply(fixture, .working, at: 2))
        #expect(working.previousActivityState == .waitingForUser)
        #expect(working.stateChanged && working.reasonChanged)
        stored = try await row(fixture)
        #expect(stored.activityState == .working)
        #expect(stored.awaitingInputReason == nil)
        #expect(stored.awaitingInputObservedAt == nil)
        #expect(stored.activityStateObservedAt == at(2))
    }

    /// A repeat of the state, the reason and the source changes nothing but
    /// the ordering watermark.
    @Test func unchangedValueDoesNotRestamp() async throws {
        let fixture = try await makeFixture()
        try await apply(fixture, .working, at: 1)

        let repeated = try #require(try await apply(fixture, .working, at: 2))
        #expect(repeated.stateChanged == false)
        #expect(repeated.reasonChanged == false)
        #expect(repeated.sourceChanged == false)
        #expect(!repeated.changed)
        #expect(repeated.previousActivityState == .working)
        let stored = try await row(fixture)
        #expect(stored.activityStateObservedAt == at(1))
    }

    /// The source is part of the value. A child exit over a session that
    /// never reported keeps `.unknown` and no reason, and still rewrites the
    /// source and its stamp, and says so: the app reads the source.
    @Test func aWriteChangingOnlyTheSourceRestampsAndReportsTheChange() async throws {
        let fixture = try await makeFixture()
        try await fixture.db.terminals.setActivityState(
            id: fixture.terminal.id, activityState: .unknown, source: .derived,
            observedAt: at(1))

        let exited = try #require(try await fixture.db.terminals.applyProgramStatusActivity(
            id: fixture.terminal.id, scope: .anyLiveIncarnation, activityState: .unknown,
            awaitingInputReason: nil, observedAt: at(2), source: .processLiveness))
        #expect(exited.stateChanged == false)
        #expect(exited.reasonChanged == false)
        #expect(exited.sourceChanged)
        #expect(exited.changed)
        let stored = try await row(fixture)
        #expect(stored.activityState == .unknown)
        #expect(stored.activityStateSource == .processLiveness)
        #expect(stored.activityStateObservedAt == at(2))
        #expect(stored.activityStateOrderObservedAt == at(2))
    }

    /// A different source is a different value, so it is ordered like one: a
    /// write not newer than the stamp is refused.
    @Test func aWriteChangingOnlyTheSourceIsRefusedWhenNotNewer() async throws {
        let fixture = try await makeFixture()
        try await fixture.db.terminals.setActivityState(
            id: fixture.terminal.id, activityState: .unknown, source: .derived,
            observedAt: at(2))

        let late = try await fixture.db.terminals.applyProgramStatusActivity(
            id: fixture.terminal.id, scope: .anyLiveIncarnation, activityState: .unknown,
            awaitingInputReason: nil, observedAt: at(2), source: .processLiveness)
        #expect(late == nil)
        #expect(try await row(fixture).activityStateSource == .derived)
    }

    /// A repeat advances only the ordering watermark, which is what refuses
    /// an older report whose write commits after it.
    @Test func aRepeatedReportStillOrdersOutAnOlderOne() async throws {
        let fixture = try await makeFixture()
        try await apply(fixture, .working, at: 1)
        try await apply(fixture, .working, at: 3)

        #expect(try await apply(fixture, .idle, at: 2) == nil)
        let stored = try await row(fixture)
        #expect(stored.activityState == .working)
        #expect(stored.activityStateObservedAt == at(1))
        #expect(stored.activityStateOrderObservedAt == at(3))
    }

    @Test func anOlderProgramStatusObservationIsRefused() async throws {
        let fixture = try await makeFixture()
        try await apply(fixture, .working, at: 2)

        #expect(try await apply(fixture, .idle, at: 1) == nil)
        let stored = try await row(fixture)
        #expect(stored.activityState == .working)
        #expect(stored.activityStateObservedAt == at(2))
    }

    /// A wake's reset leaves `.unknown` stamped by TBD (`.derived`), not by a
    /// report. A newer bare clear keeps that state and reason and rewrites
    /// only the source — the agent has now spoken — and it must fence off an
    /// older report whose write is still in flight, or the column sticks at
    /// the older value.
    @Test func aClearOverAValueTBDWroteStillOrdersOutAnOlderReport() async throws {
        let fixture = try await makeFixture()
        try await fixture.db.terminals.setActivityState(
            id: fixture.terminal.id, activityState: .unknown, source: .derived,
            observedAt: at(1))

        let cleared = try #require(try await apply(fixture, .unknown, at: 3))
        #expect(cleared.stateChanged == false)
        #expect(cleared.reasonChanged == false)
        #expect(cleared.sourceChanged)

        #expect(try await apply(fixture, .working, at: 2) == nil)
        let stored = try await row(fixture)
        #expect(stored.activityState == .unknown)
        #expect(stored.activityStateSource == .programStatus)
        #expect(stored.activityStateObservedAt == at(3))
        #expect(stored.activityStateOrderObservedAt == at(3))
    }

    /// Of two reports stamped alike, the first to commit stands: one that is
    /// not newer than the stamp is refused, unless it repeats the stored
    /// value.
    @Test func aReportAtTheStampIsRefusedUnlessItRepeatsTheValue() async throws {
        let fixture = try await makeFixture()
        try await apply(fixture, .working, at: 2)

        #expect(try await apply(fixture, .idle, at: 2) == nil)
        #expect(try await row(fixture).activityState == .working)

        let repeated = try #require(try await apply(fixture, .working, at: 2))
        #expect(repeated.stateChanged == false)
        #expect(try await row(fixture).activityStateOrderObservedAt == at(2))
    }

    @Test func refusesAParkedRow() async throws {
        let fixture = try await makeFixture()
        try await apply(fixture, .working, at: 1)
        try await fixture.db.terminals.setHibernated(
            id: fixture.terminal.id, sessionID: "acme-session", at: at(2))

        #expect(try await apply(fixture, .unknown, at: 3, scope: .anyLiveIncarnation) == nil)
        let stored = try await row(fixture)
        #expect(stored.activityState == .idle)
        #expect(stored.activityStateSource == .database)
    }

    @Test func refusesAnotherIncarnation() async throws {
        let fixture = try await makeFixture()

        #expect(try await apply(fixture, .working, at: 1, scope: .incarnation(UUID())) == nil)
        #expect(try await row(fixture).activityState == .unknown)

        #expect(try await apply(fixture, .working, at: 2) != nil)
        #expect(try await row(fixture).activityState == .working)
    }

    @Test func refusesAMissingRowWithoutThrowing() async throws {
        let fixture = try await makeFixture()
        let missing = try await fixture.db.terminals.applyProgramStatusActivity(
            id: UUID(), scope: .anyLiveIncarnation, activityState: .working,
            awaitingInputReason: nil, observedAt: at(1))
        #expect(missing == nil)
    }

    @Test func anyLiveIncarnationIgnoresTheIncarnation() async throws {
        let fixture = try await makeFixture()
        try await apply(fixture, .working, at: 1)

        let written = try #require(
            try await apply(fixture, .unknown, at: 2, scope: .anyLiveIncarnation))
        #expect(written.stateChanged)
        let stored = try await row(fixture)
        #expect(stored.activityState == .unknown)
        #expect(stored.activityStateSource == .programStatus)
    }

    @Test func workingCancelsAPendingResume() async throws {
        let fixture = try await makeFixture()
        _ = try await fixture.db.scheduledResumes.insertPending(ScheduledResume(
            terminalID: fixture.terminal.id, worktreeID: fixture.terminal.worktreeID,
            resetsAt: at(3600), fireAt: at(3660), limitType: "session", rawMessage: "m"))

        // A non-working report leaves the resume standing.
        let idle = try #require(try await apply(fixture, .idle, at: 1))
        #expect(idle.cancelledPendingResume == false)
        #expect(try await fixture.db.scheduledResumes.pending(terminalID: fixture.terminal.id) != nil)

        let working = try #require(try await apply(fixture, .working, at: 2))
        #expect(working.cancelledPendingResume)
        #expect(try await fixture.db.scheduledResumes.pending(terminalID: fixture.terminal.id) == nil)
        #expect(try await row(fixture).pendingResumeAt == nil)
        #expect(try await row(fixture).activityState == .working)
    }

    @Test func workingToIdleNotifiesTheTransition() async throws {
        let fixture = try await makeFixture()
        let fired = OSAllocatedUnfairLock<[UUID]>(initialState: [])
        fixture.db.terminals.activityTransitions.onSessionBecameIdle { profileID in
            fired.withLock { $0.append(profileID) }
        }

        // unknown -> idle is a session settling, not a turn finishing.
        try await apply(fixture, .idle, at: 1)
        try await apply(fixture, .working, at: 2)
        #expect(fired.withLock { $0 }.isEmpty)

        try await apply(fixture, .idle, at: 3)
        #expect(fired.withLock { $0 } == [fixture.profileID])
    }
}
