import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The tmux liveness sweep, and the rows it must not judge on tmux's evidence.
///
/// `reconcileTerminalsWhileLocked` probes `windowExists` for every unparked
/// tmux row and then parks the resumable Claude ones and deletes the rest. A
/// holder-backed session has no tmux coordinate at all — its `tmuxWindowID` is
/// `""`, and the repo's tmux server may never have been started — so that probe
/// can only ever answer "gone". Without the transport fork the sweep destroys a
/// live holder session on the next daemon start, which is precisely the event
/// the holder transport exists to survive.
///
/// A holder row now has an arm of its own, judged on the holder inventory
/// (`HolderReconcileInventoryTests`). This suite pins the half that arm must
/// never reach: a daemon with **no `HolderRegistry`** — mock mode, and every
/// test that does not wire one — knows nothing about holders, and "I cannot
/// ask" must stay distinct from "nobody answered".
///
/// The fork the exemption has to sit ahead of is park-versus-delete: a
/// resumable Claude row is parked and everything else is deleted outright. Both
/// suites here carry one row of each kind, so an exemption placed inside either
/// arm fails the first test, and an exemption that swallowed the whole loop
/// fails the second.
///
/// Both entry points into that loop — the per-repo `reconcile` and
/// `reconcileScratchTerminals` — funnel through the same function, so the
/// behaviour is asserted once, at the loop.
@Suite("Holder rows and the tmux reconcile")
struct HolderReconcileExemptionTests {

    private func makeLifecycle(db: TBDDatabase, tmux: TmuxManager) -> WorktreeLifecycle {
        WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver())
    }

    /// Dry-run tmux with every window reported dead.
    ///
    /// That is the same state a holder row produces against a real server:
    /// `windowExists("")` cannot succeed, and a server that was never created
    /// answers the same way. Reaching it through the hook rather than through a
    /// missing server keeps the fixture from depending on a live tmux.
    private func deadWindowTmux() -> TmuxManager {
        TmuxManager(dryRun: true, dryRunWindowIsDead: { _ in true })
    }

    /// A real git repo plus its main worktree row — the shape the sweep accepts
    /// as live, so nothing but the terminal rows is under test.
    private func seedRepo(db: TBDDatabase, at repoPath: String) async throws -> (Repo, Worktree) {
        let repo = try await db.repos.create(
            path: repoPath, displayName: "acme", defaultBranch: "main")
        let main = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoPath,
            tmuxServer: TmuxManager.serverName(forRepoPath: repoPath))
        return (repo, main)
    }

    /// No registry is wired here, deliberately: this is the daemon that cannot
    /// ask, and it must leave both rows exactly as it found them.
    @Test("a holder-backed row survives a sweep that cannot judge it, unparked")
    func holderRowSurvivesTmuxReconcile() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db, tmux: deadWindowTmux())
        let (repo, main) = try await seedRepo(db: db, at: repoDir.path)

        // Empty tmux coordinates are not a degenerate fixture: they are what
        // `HolderSpawner`'s create path writes, because there is no window.
        let claude = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-holder",
            kind: .claude, transport: .holder, holderPID: 4242, childPID: 4243)
        let shell = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            kind: .shell, transport: .holder, holderPID: 4244, childPID: 4245)

        try await lifecycle.reconcile(
            repoID: repo.id,
            actuationLog: makeTestActuationLog(),
            reapSharedScratchTmuxResources: true)

        let survivingClaude = try #require(
            try await db.terminals.get(id: claude.id),
            "the sweep deleted a holder-backed Claude row")
        #expect(
            survivingClaude.hibernatedAt == nil,
            "the sweep parked a holder-backed Claude row whose session is still running")
        #expect(survivingClaude.transport == .holder)
        #expect(
            try await db.terminals.get(id: shell.id) != nil,
            "the sweep deleted a holder-backed shell row")
    }

    /// Both values of `holder_hibernation_enabled`, because the tmux arm must
    /// be blind to it: the flag decides what a HOLDER row becomes, and a
    /// condition written to test the flag alone rather than the flag AND the
    /// transport would change this outcome too.
    @Test(
        "a tmux-backed row whose window is gone is still parked or deleted",
        arguments: [false, true])
    func tmuxRowStillReconciledNormally(holderHibernationEnabled: Bool) async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setHolderHibernationEnabled(holderHibernationEnabled)
        let lifecycle = makeLifecycle(db: db, tmux: deadWindowTmux())
        let (repo, main) = try await seedRepo(db: db, at: repoDir.path)

        let claude = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-tmux", kind: .claude)
        let shell = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "@2", tmuxPaneID: "%2", kind: .shell)

        try await lifecycle.reconcile(
            repoID: repo.id,
            actuationLog: makeTestActuationLog(),
            reapSharedScratchTmuxResources: true)

        let parked = try #require(
            try await db.terminals.get(id: claude.id),
            "the sweep deleted a resumable Claude row instead of parking it")
        #expect(
            parked.hibernatedAt != nil,
            "the exemption disabled reconciliation for the transport that still needs it")
        #expect(parked.hibernateReason == .recovery)
        #expect(
            try await db.terminals.get(id: shell.id) == nil,
            "the exemption disabled reconciliation for the transport that still needs it")
    }
}
