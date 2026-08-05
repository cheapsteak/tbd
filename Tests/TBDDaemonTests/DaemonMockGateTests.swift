import Testing
import Foundation
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// Tests that `Daemon.performStartupReconciliation` correctly gates the
/// DB-mutating startup work on `mockMode`. Avoids real socket/HTTP servers
/// by testing the extracted seam directly.
@Suite("DaemonMockGateTests")
struct DaemonMockGateTests {

    // MARK: - Mock OFF: reconciliation runs

    @Test("mock OFF: stale-path repo flipped to .missing by RepoHealthValidator")
    func mockOffRunsReconciliation() async throws {
        let db = try TBDDatabase(inMemory: true)
        let git = GitManager()
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: git,
            tmux: TmuxManager(dryRun: true),
            hooks: HookResolver()
        )

        // Seed a repo whose path definitely does not exist.
        let stalePath = "/tmp/tbd-mock-gate-nonexistent-\(UUID().uuidString)"
        _ = try await db.repos.create(
            path: stalePath,
            displayName: "ghost-repo",
            defaultBranch: "main"
        )

        // Confirm initial status is .ok (default)
        let before = try await db.repos.list()
        #expect(before.first?.status == .ok)

        // Run with mockMode == nil (live mode) — RepoHealthValidator should flip it
        await Daemon().performStartupReconciliation(
            mockMode: nil, database: db, git: git, lifecycle: lifecycle,
            actuationLog: makeTestActuationLog())

        let after = try await db.repos.list()
        #expect(after.first?.status == .missing)
    }

    // MARK: - Mock ON: reconciliation skipped

    @Test("mock ON: stale-path repo stays .ok (reconciliation skipped)")
    func mockOnSkipsReconciliation() async throws {
        let db = try TBDDatabase(inMemory: true)
        let git = GitManager()
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: git,
            tmux: TmuxManager(dryRun: true),
            hooks: HookResolver()
        )

        let stalePath = "/tmp/tbd-mock-gate-nonexistent-\(UUID().uuidString)"
        let repo = try await db.repos.create(
            path: stalePath,
            displayName: "ghost-repo",
            defaultBranch: "main"
        )
        _ = try await db.worktrees.create(
            repoID: repo.id,
            name: "main",
            displayName: "Main",
            branch: "main",
            path: stalePath + "/.tbd/worktrees/main",
            tmuxServer: "mock-server",
            status: .main
        )

        // Run with mockMode == .enabled — reconciliation should be skipped
        await Daemon().performStartupReconciliation(
            mockMode: .enabled(fixturePath: "/tmp/x.json"),
            database: db, git: git, lifecycle: lifecycle,
            actuationLog: makeTestActuationLog())

        // Repo should still be .ok (RepoHealthValidator never ran)
        let repos = try await db.repos.list()
        #expect(repos.first?.status == .ok)

        // Worktree should still exist (reconcile loop never ran)
        let worktrees = try await db.worktrees.list(repoID: repo.id)
        #expect(worktrees.count == 1)
    }
}
