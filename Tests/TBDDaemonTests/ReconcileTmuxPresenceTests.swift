import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// What the startup reconcile does when the tmux probe fails to answer.
///
/// The pass parks resumable Claude rows and deletes everything else the moment
/// it believes a window is gone, and until the tri-state probes it believed
/// that on a timeout. On 2026-09-02 a restart of a busy machine parked 49 of 56
/// live lane sessions in one pass, every row carrying the same `hibernatedAt`.
/// Nothing was gone; the probes were merely slow.
///
/// Each test carries one resumable Claude row and one shell row, because the
/// pass forks on exactly that: park versus delete. A guard placed inside either
/// arm fails one of these tests, and a guard that swallowed the whole loop
/// fails `absentStillParksAndDeletes`.
@Suite("Reconcile and unanswered tmux probes")
struct ReconcileTmuxPresenceTests {

    private func makeLifecycle(db: TBDDatabase, tmux: TmuxManager) -> WorktreeLifecycle {
        WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver())
    }

    private func seedRepo(db: TBDDatabase, at repoPath: String) async throws -> (Repo, Worktree) {
        let repo = try await db.repos.create(
            path: repoPath, displayName: "acme", defaultBranch: "main")
        let main = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoPath,
            tmuxServer: TmuxManager.serverName(forRepoPath: repoPath))
        return (repo, main)
    }

    private func seedTerminals(
        db: TBDDatabase, worktree: Worktree
    ) async throws -> (claude: Terminal, shell: Terminal) {
        let claude = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-tmux", kind: .claude)
        let shell = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@2", tmuxPaneID: "%2", kind: .shell)
        return (claude, shell)
    }

    private func runReconcile(
        tmux: TmuxManager
    ) async throws -> (db: TBDDatabase, claude: UUID, shell: UUID, cleanup: () -> Void) {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db, tmux: tmux)
        let (repo, main) = try await seedRepo(db: db, at: repoDir.path)
        let rows = try await seedTerminals(db: db, worktree: main)
        try await lifecycle.reconcile(
            repoID: repo.id,
            actuationLog: makeTestActuationLog(),
            reapSharedScratchTmuxResources: true)
        return (db, rows.claude.id, rows.shell.id, { try? FileManager.default.removeItem(at: tempDir) })
    }

    /// A server probe that never answered is ignorance about every row on that
    /// server, so every row on it is left exactly as it was.
    @Test("an unanswered server probe touches nothing")
    func unknownServerLeavesRowsAlone() async throws {
        let tmux = TmuxManager(
            dryRun: true,
            dryRunWindowIsDead: { _ in true },
            dryRunServerPresence: { _ in .unknown })
        let run = try await runReconcile(tmux: tmux)
        defer { run.cleanup() }

        let claude = try #require(
            try await run.db.terminals.get(id: run.claude),
            "an unanswered server probe deleted a live Claude row")
        #expect(claude.hibernatedAt == nil,
                "an unanswered server probe parked a live Claude row")
        #expect(try await run.db.terminals.get(id: run.shell) != nil,
                "an unanswered server probe deleted a live shell row")
    }

    /// The server answered, the window probe did not. Same rule, one level down.
    @Test("an unanswered window probe touches nothing")
    func unknownWindowLeavesRowsAlone() async throws {
        let tmux = TmuxManager(
            dryRun: true,
            dryRunWindowIsDead: { _ in true },
            dryRunServerPresence: { _ in .alive },
            dryRunWindowPresence: { _, _ in .unknown })
        let run = try await runReconcile(tmux: tmux)
        defer { run.cleanup() }

        let claude = try #require(
            try await run.db.terminals.get(id: run.claude),
            "an unanswered window probe deleted a live Claude row")
        #expect(claude.hibernatedAt == nil,
                "an unanswered window probe parked a live Claude row")
        #expect(try await run.db.terminals.get(id: run.shell) != nil,
                "an unanswered window probe deleted a live shell row")
    }

    /// Positive evidence still acts, and acts the way it always did. Without
    /// this the tri-state could be satisfied by a pass that does nothing.
    @Test("a window tmux says is gone is still parked or deleted")
    func absentStillParksAndDeletes() async throws {
        let tmux = TmuxManager(
            dryRun: true,
            dryRunServerPresence: { _ in .alive },
            dryRunWindowPresence: { _, _ in .absent })
        let run = try await runReconcile(tmux: tmux)
        defer { run.cleanup() }

        let parked = try #require(
            try await run.db.terminals.get(id: run.claude),
            "a resumable Claude row was deleted instead of parked")
        #expect(parked.hibernatedAt != nil,
                "the tri-state probe stopped reconcile acting on positive evidence")
        #expect(parked.hibernateReason == .recovery)
        #expect(try await run.db.terminals.get(id: run.shell) == nil,
                "the tri-state probe stopped reconcile deleting a non-resumable row")
    }

    /// A server tmux says is gone has positively no windows on it, so the rows
    /// under it are reconciled without ever probing a window.
    @Test("an absent server parks and deletes without a window probe")
    func absentServerActsWithoutWindowProbe() async throws {
        let tmux = TmuxManager(
            dryRun: true,
            dryRunServerPresence: { _ in .absent },
            dryRunWindowPresence: { _, _ in
                Issue.record("reconcile probed a window on a server tmux said was gone")
                return .alive
            })
        let run = try await runReconcile(tmux: tmux)
        defer { run.cleanup() }

        let parked = try #require(try await run.db.terminals.get(id: run.claude))
        #expect(parked.hibernatedAt != nil)
        #expect(try await run.db.terminals.get(id: run.shell) == nil)
    }

    /// The repair half, at the seam `Daemon.start()` calls.
    ///
    /// `Daemon.start()` runs `hibernationCoordinator.reconcileOnStartup()`
    /// twice: once at step 8d before `performStartupReconciliation`, and once
    /// straight after it (step 8d-ii). Only the second run can undo a park the
    /// same boot made, and this composes the two halves the way that step does
    /// — reconcile parks a row on a window probe that answered absent, then the
    /// un-park pass finds the pane demonstrably still running Claude and
    /// clears it. `Daemon.start()` itself binds listeners and cannot be driven
    /// from a unit test, so the ordering is asserted here and the call site is
    /// cited above.
    @Test("the post-reconcile un-park pass clears a park made by the same boot")
    func secondUnparkPassRepairsSameBootPark() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let parkingTmux = TmuxManager(
            dryRun: true,
            dryRunServerPresence: { _ in .alive },
            dryRunWindowPresence: { _, _ in .absent })
        let lifecycle = makeLifecycle(db: db, tmux: parkingTmux)
        let (repo, main) = try await seedRepo(db: db, at: repoDir.path)
        let rows = try await seedTerminals(db: db, worktree: main)

        try await lifecycle.reconcile(
            repoID: repo.id,
            actuationLog: makeTestActuationLog(),
            reapSharedScratchTmuxResources: true)

        let parked = try #require(try await db.terminals.get(id: rows.claude.id))
        #expect(parked.hibernatedAt != nil, "the fixture did not produce a park to repair")

        // The window is there after all and the pane is running Claude — the
        // race the second pass exists for. The un-park pass still asks the
        // `Bool` probes, whose dry-run default is "alive"; a wrong `false`
        // there only leaves a row parked, which is the conservative direction.
        // `dryRunPaneCurrentCommand` reporting a version string is how the
        // existing coordinator fixtures spell "a live claude process".
        let repairingTmux = TmuxManager(
            dryRun: true,
            dryRunPaneCurrentCommand: { _, _ in "1.2.3" })
        let coordinator = HibernationCoordinator(
            db: db, tmux: repairingTmux,
            configDirManager: makeIsolatedConfigDirManager(tag: "reconcile-unpark"),
            actuationLog: makeTestActuationLog())
        await coordinator.reconcileOnStartup()

        let repaired = try #require(try await db.terminals.get(id: rows.claude.id))
        #expect(repaired.hibernatedAt == nil,
                "the post-reconcile un-park pass left a same-boot park in place")
        #expect(repaired.claudeSessionID == parked.claudeSessionID)
    }
}
