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

    private func makeWorktree(_ db: TBDDatabase) async throws -> Worktree {
        let repo = try await db.repos.create(
            path: "/tmp/nhbr-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        return try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/nhbr-wt-\(UUID().uuidString)", tmuxServer: "tbd-nhbr")
    }

    private func run(_ db: TBDDatabase, _ applied: AppliedModes) async throws -> NightwatchMode? {
        try await NightwatchHolderBootReconcile.run(
            db: db, subscriptions: StateSubscriptionManager(),
            applyMode: { await applied.append($0) })
    }

    @Test func bothOnTurnsModeOffNotifiesAndDoesNotStartTheRunner() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPtyHolderEnabled(true)
        try await db.config.setNightwatchMode(.nightwatch)
        let wt = try await makeWorktree(db)
        let applied = AppliedModes()

        let result = try await run(db, applied)

        #expect(result == nil)
        #expect(try await db.config.get().nightwatchMode == .off)
        let notes = try await db.notifications.unread(worktreeID: wt.id)
        #expect(notes.count == 1)
        #expect(notes.first?.type == .attentionNeeded)
        #expect(notes.first?.message == NightwatchHolderGate.modeRefusal)
        #expect(await applied.modes.isEmpty)
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

    @Test func bootReconcileWithNoWorktreeStillTurnsModeOff() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPtyHolderEnabled(true)
        try await db.config.setNightwatchMode(.nightwatch)
        let applied = AppliedModes()

        let result = try await run(db, applied)

        #expect(result == nil)
        #expect(try await db.config.get().nightwatchMode == .off)
        #expect(await applied.modes.isEmpty)
    }

    @Test func holderOffAppliesThePersistedModeUnchanged() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPtyHolderEnabled(false)
        try await db.config.setNightwatchMode(.daywatch)
        let wt = try await makeWorktree(db)
        let applied = AppliedModes()

        let result = try await run(db, applied)

        #expect(result == .daywatch)
        #expect(try await db.config.get().nightwatchMode == .daywatch)
        #expect(await applied.modes == [.daywatch])
        #expect(try await db.notifications.unread(worktreeID: wt.id).isEmpty)
    }

    @Test func modeOffWithHolderOnAppliesOff() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPtyHolderEnabled(true)
        try await db.config.setNightwatchMode(.off)
        let wt = try await makeWorktree(db)
        let applied = AppliedModes()

        let result = try await run(db, applied)

        #expect(result == .off)
        #expect(await applied.modes == [.off])
        #expect(try await db.notifications.unread(worktreeID: wt.id).isEmpty)
    }
}
