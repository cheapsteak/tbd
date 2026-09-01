import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Thread-safe recorder for the store's `working -> idle` fan-out.
private final class IdleTransitionRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "IdleTransitionRecorder")
    private var _profileIDs: [UUID] = []
    var profileIDs: [UUID] { queue.sync { _profileIDs } }
    func record(_ id: UUID) { queue.sync { _profileIDs.append(id) } }
}

/// The `working -> idle` edge is detected inside `TerminalStore` because BOTH
/// of its activity writers commit it. These tests pin the edge itself: which
/// transitions fire, which deliberately do not, and that the profile id
/// travelling with it is the terminal's own.
@Suite("terminal activity transition fan-out")
struct TerminalActivityTransitionNotifierTests {

    private func makeTerminal(
        in db: TBDDatabase,
        tag: String,
        profileID: UUID?
    ) async throws -> Terminal {
        let repo = try await db.repos.create(
            path: "/tmp/tat-\(tag)-repo-\(UUID().uuidString)",
            displayName: "tat-\(tag)", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/tat-\(tag)-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-tat-\(tag)")
        return try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, profileID: profileID, kind: .claude)
    }

    // MARK: applyActivityObservation — the path real Claude hooks take

    @Test func hookPathNotifiesOnWorkingToIdleWithTheTerminalsProfile() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorder = IdleTransitionRecorder()
        db.terminals.activityTransitions.onSessionBecameIdle { recorder.record($0) }

        let profileID = UUID()
        let terminal = try await makeTerminal(in: db, tag: "hook", profileID: profileID)
        let base = Date(timeIntervalSince1970: 1_790_000_000)

        _ = try await db.terminals.applyActivityObservation(
            id: terminal.id, activityState: .working,
            source: .hookEvent("UserPromptSubmit"), observedAt: base)
        #expect(recorder.profileIDs.isEmpty)

        _ = try await db.terminals.applyActivityObservation(
            id: terminal.id, activityState: .idle,
            source: .hookEvent("Stop"), observedAt: base.addingTimeInterval(1))

        #expect(recorder.profileIDs == [profileID])
    }

    /// The off-branch that keeps this from firing on every session start: only
    /// `working -> idle` says a turn completed and utilization moved.
    @Test func hookPathDoesNotNotifyWhenIdleArrivesFromUnknown() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorder = IdleTransitionRecorder()
        db.terminals.activityTransitions.onSessionBecameIdle { recorder.record($0) }

        let terminal = try await makeTerminal(in: db, tag: "fresh", profileID: UUID())
        // A freshly created terminal is `.unknown`; go straight to idle.
        _ = try await db.terminals.applyActivityObservation(
            id: terminal.id, activityState: .idle, source: .hookEvent("Stop"),
            observedAt: Date(timeIntervalSince1970: 1_790_000_000))

        #expect(recorder.profileIDs.isEmpty)
    }

    @Test func hookPathDoesNotNotifyOnWorkingToWaitingForUser() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorder = IdleTransitionRecorder()
        db.terminals.activityTransitions.onSessionBecameIdle { recorder.record($0) }

        let terminal = try await makeTerminal(in: db, tag: "waiting", profileID: UUID())
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try await db.terminals.applyActivityObservation(
            id: terminal.id, activityState: .working,
            source: .hookEvent("UserPromptSubmit"), observedAt: base)
        _ = try await db.terminals.applyActivityObservation(
            id: terminal.id, activityState: .waitingForUser,
            source: .hookEvent("Notification"), observedAt: base.addingTimeInterval(1))

        #expect(recorder.profileIDs.isEmpty)
    }

    /// A repeated `Stop` is the same durable value, so no second edge — the
    /// notification tracks transitions, not observations.
    @Test func repeatedIdleObservationNotifiesOnlyOnce() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorder = IdleTransitionRecorder()
        db.terminals.activityTransitions.onSessionBecameIdle { recorder.record($0) }

        let profileID = UUID()
        let terminal = try await makeTerminal(in: db, tag: "repeat", profileID: profileID)
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try await db.terminals.applyActivityObservation(
            id: terminal.id, activityState: .working,
            source: .hookEvent("UserPromptSubmit"), observedAt: base)
        _ = try await db.terminals.applyActivityObservation(
            id: terminal.id, activityState: .idle,
            source: .hookEvent("Stop"), observedAt: base.addingTimeInterval(1))
        _ = try await db.terminals.applyActivityObservation(
            id: terminal.id, activityState: .idle,
            source: .hookEvent("Stop"), observedAt: base.addingTimeInterval(2))

        #expect(recorder.profileIDs == [profileID])
    }

    /// A terminal spawned without a profile has no usage to refresh, so the
    /// edge is real but carries nobody.
    @Test func terminalWithoutAProfileNotifiesNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorder = IdleTransitionRecorder()
        db.terminals.activityTransitions.onSessionBecameIdle { recorder.record($0) }

        let terminal = try await makeTerminal(in: db, tag: "noprofile", profileID: nil)
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try await db.terminals.applyActivityObservation(
            id: terminal.id, activityState: .working,
            source: .hookEvent("UserPromptSubmit"), observedAt: base)
        _ = try await db.terminals.applyActivityObservation(
            id: terminal.id, activityState: .idle,
            source: .hookEvent("Stop"), observedAt: base.addingTimeInterval(1))

        #expect(recorder.profileIDs.isEmpty)
    }

    /// No observer installed is the default state for every test database and
    /// for a daemon that never wired one. It must not crash or change behavior.
    @Test func writesSucceedWithNoObserverInstalled() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeTerminal(in: db, tag: "noobs", profileID: UUID())
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try await db.terminals.applyActivityObservation(
            id: terminal.id, activityState: .working,
            source: .hookEvent("UserPromptSubmit"), observedAt: base)
        let applied = try await db.terminals.applyActivityObservation(
            id: terminal.id, activityState: .idle,
            source: .hookEvent("Stop"), observedAt: base.addingTimeInterval(1))
        #expect(applied?.activityState == .idle)
    }

    // MARK: setActivityState — the second writer

    @Test func setActivityStateNotifiesOnWorkingToIdle() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorder = IdleTransitionRecorder()
        db.terminals.activityTransitions.onSessionBecameIdle { recorder.record($0) }

        let profileID = UUID()
        let terminal = try await makeTerminal(in: db, tag: "setstate", profileID: profileID)
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .working, source: .hookEvent("UserPromptSubmit"))
        #expect(recorder.profileIDs.isEmpty)

        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .idle, source: .hookEvent("Stop"))

        #expect(recorder.profileIDs == [profileID])
    }

    @Test func setActivityStateDoesNotNotifyWhenIdleArrivesFromUnknown() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorder = IdleTransitionRecorder()
        db.terminals.activityTransitions.onSessionBecameIdle { recorder.record($0) }

        let terminal = try await makeTerminal(in: db, tag: "setfresh", profileID: UUID())
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .idle, source: .hookEvent("Stop"))

        #expect(recorder.profileIDs.isEmpty)
    }

    /// The retraction return value is what callers already depend on; wrapping
    /// the transaction result must not change it.
    @Test func setActivityStateStillReportsARetractedWaitReason() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeTerminal(in: db, tag: "retract", profileID: UUID())
        let base = Date(timeIntervalSince1970: 1_790_000_000)

        let installed = try await db.terminals.setActivityState(
            id: terminal.id, activityState: .working, source: .hookEvent("Notification"),
            observedAt: base, awaitingInputReason: AwaitingInputReason(message: "Claude needs your permission"))
        #expect(installed == false)  // a call that INSTALLS a reason retracts nothing

        let retracted = try await db.terminals.setActivityState(
            id: terminal.id, activityState: .idle, source: .hookEvent("Stop"),
            observedAt: base.addingTimeInterval(1))
        #expect(retracted == true)
    }
}
