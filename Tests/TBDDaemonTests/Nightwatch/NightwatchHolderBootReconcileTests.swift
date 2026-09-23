import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The boot reconcile for an install that combined a watch mode with the
/// pty-holder transport on a daemon older than the gate: the mode is turned
/// off once, the user is told why, and the runner is not started. Every other
/// combination re-applies the persisted mode unchanged.
@Suite("Nightwatch/holder boot reconcile")
struct NightwatchHolderBootReconcileTests {

    /// Records the modes handed to the runner.
    private actor AppliedModes {
        var modes: [NightwatchMode] = []
        func append(_ mode: NightwatchMode) { modes.append(mode) }
    }

    /// Thread-safe collector for broadcast `StateDelta`s, same shape as the
    /// one used across `Tests/TBDDaemonTests` (see `NotificationHookRPCTests`).
    private final class BroadcastDeltas: @unchecked Sendable {
        private let lock = NSLock()
        private var deltas: [StateDelta] = []

        func append(_ delta: StateDelta) {
            lock.lock(); defer { lock.unlock() }
            deltas.append(delta)
        }

        func snapshot() -> [StateDelta] {
            lock.lock(); defer { lock.unlock() }
            return deltas
        }

        func count(matching predicate: (StateDelta) -> Bool) -> Int {
            snapshot().filter(predicate).count
        }
    }

    private func makeWorktree(_ db: TBDDatabase) async throws -> Worktree {
        let repo = try await db.repos.create(
            path: "/tmp/nhbr-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        return try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/nhbr-wt-\(UUID().uuidString)", tmuxServer: "tbd-nhbr")
    }

    /// Wires a fresh `StateSubscriptionManager` with a subscriber that
    /// captures every broadcast delta (synchronously — `broadcast(delta:)`
    /// fans out before returning, so the snapshot is complete once `run`
    /// returns) and hands both the result and the collector back.
    private func run(_ db: TBDDatabase, _ applied: AppliedModes) async throws -> (NightwatchMode?, BroadcastDeltas) {
        let broadcasts = BroadcastDeltas()
        let subscriptions = StateSubscriptionManager()
        subscriptions.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                broadcasts.append(delta)
            }
            return true
        }
        let result = try await NightwatchHolderBootReconcile.run(
            db: db, subscriptions: subscriptions,
            applyMode: { await applied.append($0) })
        return (result, broadcasts)
    }

    private func isModelProfilesChanged(_ delta: StateDelta) -> Bool {
        if case .modelProfilesChanged = delta { return true }
        return false
    }

    private func isNotificationReceived(_ delta: StateDelta) -> Bool {
        if case .notificationReceived = delta { return true }
        return false
    }

    @Test func bothOnTurnsModeOffNotifiesAndDoesNotStartTheRunner() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPtyHolderEnabled(true)
        try await db.config.setNightwatchMode(.nightwatch)
        let wt = try await makeWorktree(db)
        let applied = AppliedModes()

        let (result, broadcasts) = try await run(db, applied)

        #expect(result == nil)
        #expect(try await db.config.get().nightwatchMode == .off)
        let notes = try await db.notifications.unread(worktreeID: wt.id)
        #expect(notes.count == 1)
        #expect(notes.first?.type == .attentionNeeded)
        #expect(notes.first?.message == NightwatchHolderGate.modeRefusal)
        #expect(await applied.modes.isEmpty)
        #expect(broadcasts.count(matching: isModelProfilesChanged) == 1)
        #expect(broadcasts.count(matching: isNotificationReceived) == 1)
    }

    @Test func deskScratchWorktreeIsPreferredForTheNotification() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPtyHolderEnabled(true)
        try await db.config.setNightwatchMode(.daywatch)
        let other = try await makeWorktree(db)
        let desk = try await db.worktrees.createScratch(
            name: "desk", displayName: NightwatchDeskPrompts.deskDisplayName,
            path: "/tmp/nhbr-desk-\(UUID().uuidString)", tmuxServer: "tbd-nhbr")
        let applied = AppliedModes()

        _ = try await run(db, applied)

        let deskNotes = try await db.notifications.unread(worktreeID: desk.id)
        #expect(deskNotes.count == 1)
        #expect(deskNotes.first?.message == NightwatchHolderGate.modeRefusal)
        #expect(try await db.notifications.unread(worktreeID: other.id).isEmpty)
    }

    /// Even with no worktree to carry the notification, the mode write and
    /// its `.modelProfilesChanged` broadcast still happen — the notification
    /// leg is best-effort and independent of them.
    @Test func bootReconcileWithNoWorktreeStillTurnsModeOff() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPtyHolderEnabled(true)
        try await db.config.setNightwatchMode(.nightwatch)
        let applied = AppliedModes()

        let (result, broadcasts) = try await run(db, applied)

        #expect(result == nil)
        #expect(try await db.config.get().nightwatchMode == .off)
        #expect(await applied.modes.isEmpty)
        #expect(broadcasts.count(matching: isModelProfilesChanged) == 1)
        #expect(broadcasts.count(matching: isNotificationReceived) == 0)
    }

    @Test func holderOffAppliesThePersistedModeUnchanged() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPtyHolderEnabled(false)
        try await db.config.setNightwatchMode(.daywatch)
        let wt = try await makeWorktree(db)
        let applied = AppliedModes()

        let (result, broadcasts) = try await run(db, applied)

        #expect(result == .daywatch)
        #expect(try await db.config.get().nightwatchMode == .daywatch)
        #expect(await applied.modes == [.daywatch])
        #expect(try await db.notifications.unread(worktreeID: wt.id).isEmpty)
        #expect(broadcasts.count(matching: isModelProfilesChanged) == 0)
        #expect(broadcasts.count(matching: isNotificationReceived) == 0)
    }

    @Test func modeOffWithHolderOnAppliesOff() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPtyHolderEnabled(true)
        try await db.config.setNightwatchMode(.off)
        let wt = try await makeWorktree(db)
        let applied = AppliedModes()

        let (result, broadcasts) = try await run(db, applied)

        #expect(result == .off)
        #expect(await applied.modes == [.off])
        #expect(try await db.notifications.unread(worktreeID: wt.id).isEmpty)
        #expect(broadcasts.count(matching: isModelProfilesChanged) == 0)
        #expect(broadcasts.count(matching: isNotificationReceived) == 0)
    }
}
