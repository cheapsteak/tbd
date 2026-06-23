import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct AutoArchiveTriggerTests {
    @Test func firesOnTransitionIntoMerged() async throws {
        let mgr = PRStatusManager()
        let box = FiredBox()
        await mgr.setOnMergedTransition { id, num in await box.record(id, num) }

        let wtID = UUID()
        // First observation: open → no fire.
        await mgr.seedForTesting(worktreeID: wtID,
            status: PRStatus(number: 7, url: "u", state: .mergeable, reason: "ok"))
        #expect(await box.count == 0)

        // Transition into merged → fires once with the PR number.
        await mgr.seedForTesting(worktreeID: wtID,
            status: PRStatus(number: 7, url: "u", state: .merged, reason: "Merged"))
        #expect(await box.count == 1)
        #expect(await box.lastNumber == 7)

        // Stays merged → no second fire.
        await mgr.seedForTesting(worktreeID: wtID,
            status: PRStatus(number: 7, url: "u", state: .merged, reason: "Merged"))
        #expect(await box.count == 1)
    }
}

actor FiredBox {
    var count = 0
    var lastNumber = 0
    func record(_ id: UUID, _ number: Int) { count += 1; lastNumber = number }
}

@Suite struct AutoArchiveCoordinatorTests {
    private func makeDeps() throws -> (AutoArchiveOnMergeCoordinator, TBDDatabase) {
        let db = try TBDDatabase(inMemory: true)
        let subs = StateSubscriptionManager()
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(dryRun: true),
            hooks: HookResolver(),
            subscriptions: subs
        )
        let coord = AutoArchiveOnMergeCoordinator(db: db, lifecycle: lifecycle, subscriptions: subs)
        return (coord, db)
    }

    @Test func archivesWhenEffectiveOnAndNoChildren() async throws {
        let (coord, db) = try makeDeps()
        let repo = try await db.repos.create(
            path: "/tmp/repoC-\(UUID().uuidString)", displayName: "repoC", defaultBranch: "main")
        let wt = try await db.worktrees.create(repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/repoC/w-\(UUID().uuidString)", tmuxServer: "s")
        try await db.worktrees.setAutoArchiveOnMerge(id: wt.id, value: true)

        await coord.handleMergedTransition(worktreeID: wt.id, prNumber: 5)

        let after = try await db.worktrees.get(id: wt.id)
        #expect(after?.status == .archived)

        let notifications = try await db.notifications.unread(worktreeID: wt.id)
        #expect(notifications.count == 1)
        #expect(notifications.first?.type == .taskComplete)
        #expect(notifications.first?.message?.contains("#5") == true)
    }

    @Test func doesNotArchiveWhenEffectiveOff() async throws {
        let (coord, db) = try makeDeps()
        let repo = try await db.repos.create(
            path: "/tmp/repoD-\(UUID().uuidString)", displayName: "repoD", defaultBranch: "main")
        let wt = try await db.worktrees.create(repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/repoD/w-\(UUID().uuidString)", tmuxServer: "s")
        try await db.worktrees.setAutoArchiveOnMerge(id: wt.id, value: false)

        await coord.handleMergedTransition(worktreeID: wt.id, prNumber: 5)
        #expect(try await db.worktrees.get(id: wt.id)?.status == .active)
    }

    @Test func doesNotArchiveWithActiveChildren() async throws {
        let (coord, db) = try makeDeps()
        let repo = try await db.repos.create(
            path: "/tmp/repoE-\(UUID().uuidString)", displayName: "repoE", defaultBranch: "main")
        let parent = try await db.worktrees.create(repoID: repo.id, name: "p", branch: "bp",
            path: "/tmp/repoE/p-\(UUID().uuidString)", tmuxServer: "s")
        _ = try await db.worktrees.create(repoID: repo.id, name: "c", branch: "bc",
            path: "/tmp/repoE/c-\(UUID().uuidString)", tmuxServer: "s",
            parentWorktreeID: parent.id)
        try await db.worktrees.setAutoArchiveOnMerge(id: parent.id, value: true)

        await coord.handleMergedTransition(worktreeID: parent.id, prNumber: 5)
        #expect(try await db.worktrees.get(id: parent.id)?.status == .active)
    }

    @Test func respectsGlobalDefaultWhenOverrideNil() async throws {
        let (coord, db) = try makeDeps()
        try await db.config.setAutoArchiveOnMergeDefault(true)
        let repo = try await db.repos.create(
            path: "/tmp/repoF-\(UUID().uuidString)", displayName: "repoF", defaultBranch: "main")
        let wt = try await db.worktrees.create(repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/repoF/w-\(UUID().uuidString)", tmuxServer: "s")
        // override stays nil → follows global default (on)
        await coord.handleMergedTransition(worktreeID: wt.id, prNumber: 9)
        #expect(try await db.worktrees.get(id: wt.id)?.status == .archived)
    }
}
