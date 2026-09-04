import Testing
import TestSupport
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

// Nested under TBDHomeSerialized: scratch.create resolves
// TBDConstants.scratchDir from the process-global TBD_HOME, and
// TBD_CLAUDE_HOST_HOME keeps the ambient projects root off the developer's
// real ~/.claude. See TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {

/// Regression suite for the promote → reconcile interaction: reconcile's
/// stale-tmux-server self-heal must NOT revert a promoted-main worktree's
/// deliberately inherited scratch server while its windows are live (doing so
/// probed the empty canonical server, declared every window dead, parked the
/// Claude terminals and deleted the shell rows). The self-heal must still
/// canonicalize when the stored server genuinely has no live windows.
@Suite("scratch.promote + reconcile interaction")
struct ScratchPromoteReconcileTests {
    private func isolate() -> (URL, () -> Void) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-promote-rec-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let priorTBDHome = setTBDHome(home.path)
        let priorClaudeHost = setClaudeHostHome(home.appendingPathComponent("claude-host").path)
        return (home, {
            restoreTBDHome(priorTBDHome)
            restoreClaudeHostHome(priorClaudeHost)
            try? FileManager.default.removeItem(at: home)
        })
    }

    private func makeRouter(_ db: TBDDatabase, home: URL) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            configDirManager: ClaudeProfileConfigDirManager(
                baseDirectory: home.appendingPathComponent("profiles", isDirectory: true),
                hostBaseDirectory: home.appendingPathComponent("claude-host", isDirectory: true)
            ),
            actuationLog: makeTestActuationLog()
        )
    }

    private func gitInitCommit(at path: String) throws {
        for args in [["init"], ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"]] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", path] + args; try p.run(); p.waitUntilExit()
        }
    }

    /// Promote a scratch space carrying two live-ish terminals, returning
    /// everything the reconcile assertions need.
    private func promoteScratchWithTerminals(
        db: TBDDatabase, router: RPCRouter, home: URL
    ) async throws -> (scratch: Worktree, repoID: UUID, dest: String,
                       mainWorktree: Worktree, claude: Terminal, shell: Terminal) {
        let created = await router.handle(try RPCRequest(
            method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: nil)))
        let wt = try created.decodeResult(Worktree.self)
        try gitInitCommit(at: wt.localPath)
        // The scratch.create RPC now auto-spawns a default primary agent terminal;
        // clear it so this test controls its own terminal fixture.
        try await db.terminals.deleteForWorktree(worktreeID: wt.id)

        let claude = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "sess-1", kind: .claude)
        let shell = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: "shell", kind: .shell)

        let dest = home.appendingPathComponent("projects/promoted-app").path
        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.scratchPromote,
            params: ScratchPromoteParams(worktreeID: wt.id, destPath: dest, displayName: nil)))
        #expect(resp.success)
        let result = try resp.decodeResult(ScratchPromoteResult.self)
        let mainWt = try #require(
            try await db.worktrees.list(repoID: result.repoID, status: .main).first)
        return (wt, result.repoID, dest, mainWt, claude, shell)
    }

    @Test func reconcilePreservesInheritedServerAndTerminalsWhenWindowsLive() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db, home: home)
        let promoted = try await promoteScratchWithTerminals(db: db, router: router, home: home)

        // Sanity: the inherited scratch server is NOT the canonical name for
        // the promoted repo path — otherwise this test proves nothing.
        let canonical = TmuxManager.serverName(forRepoPath: promoted.dest)
        #expect(promoted.mainWorktree.tmuxServer != canonical)
        #expect(promoted.mainWorktree.tmuxServer == promoted.scratch.tmuxServer)

        // dryRun tmux without dryRunWindowIsDead reports every window ALIVE —
        // the live-session case reconcile must leave alone.
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver())
        try await lifecycle.reconcile(repoID: promoted.repoID, actuationLog: makeTestActuationLog(), reapSharedScratchTmuxResources: true)

        // The inherited tmux server survives reconcile.
        let mainAfter = try #require(try await db.worktrees.get(id: promoted.mainWorktree.id))
        #expect(mainAfter.tmuxServer == promoted.scratch.tmuxServer)

        // Terminal rows intact: nothing parked, nothing deleted.
        let terminals = try await db.terminals.list(worktreeID: promoted.mainWorktree.id)
        #expect(Set(terminals.map(\.id)) == [promoted.claude.id, promoted.shell.id])
        let claudeAfter = try #require(terminals.first(where: { $0.id == promoted.claude.id }))
        #expect(claudeAfter.hibernatedAt == nil)
        #expect(claudeAfter.suspendedAt == nil)
    }

    /// The self-heal's negative branch is destructive — it rewrites the stored
    /// server, which orphans any live window on the old one, and the very next
    /// pass then reads those orphans as dead and parks or deletes rows whose
    /// sessions are running. The comment above the loop has always said so.
    ///
    /// The probe behind it could not say "I could not check": `serverExists` and
    /// `windowExists` both folded every tmux failure into `false`, the same
    /// signal as a genuinely dead server. So a transient tmux fault coinciding
    /// with an inherited server name was enough to trigger the cascade the
    /// comment warns about, with no fault of the stored data.
    ///
    /// Here the windows are alive and the identity of the server is fine — only
    /// the consultation fails. Nothing may be rewritten on that.
    @Test func reconcileKeepsInheritedServerWhenTmuxCannotBeConsulted() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db, home: home)
        let promoted = try await promoteScratchWithTerminals(db: db, router: router, home: home)

        let canonical = TmuxManager.serverName(forRepoPath: promoted.dest)
        #expect(promoted.mainWorktree.tmuxServer != canonical, "fixture proves nothing otherwise")

        // Every window consultation fails to run — not an answer about any window.
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(
                dryRun: true,
                dryRunWindowExistence: { _, _ in
                    .unverifiable(error: "tmux list-panes exited 1: error connecting to socket")
                }
            ),
            hooks: HookResolver())
        try await lifecycle.reconcile(
            repoID: promoted.repoID, actuationLog: makeTestActuationLog(),
            reapSharedScratchTmuxResources: true)

        let mainAfter = try #require(try await db.worktrees.get(id: promoted.mainWorktree.id))
        #expect(
            mainAfter.tmuxServer == promoted.scratch.tmuxServer,
            "a tmux nobody could consult must not license rewriting the stored server")

        let terminals = try await db.terminals.list(worktreeID: promoted.mainWorktree.id)
        #expect(Set(terminals.map(\.id)) == [promoted.claude.id, promoted.shell.id])
    }

    /// An unreachable *server* is the other half of the same probe, and it fails
    /// the same way: `serverExists` returned `false` for "no server running" and
    /// for "I could not reach tmux" alike.
    @Test func reconcileKeepsInheritedServerWhenServerCannotBeReached() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db, home: home)
        let promoted = try await promoteScratchWithTerminals(db: db, router: router, home: home)

        let lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(
                dryRun: true,
                dryRunServerExistence: { _ in
                    .unverifiable(error: "protocol version mismatch (client 8, server 7)")
                }
            ),
            hooks: HookResolver())
        try await lifecycle.reconcile(
            repoID: promoted.repoID, actuationLog: makeTestActuationLog(),
            reapSharedScratchTmuxResources: true)

        let mainAfter = try #require(try await db.worktrees.get(id: promoted.mainWorktree.id))
        #expect(
            mainAfter.tmuxServer == promoted.scratch.tmuxServer,
            "an unreachable tmux server is not a dead one")
    }

    /// The other direction, so refusing to act on absence of evidence did not
    /// become refusing to act on evidence: when tmux positively reports the
    /// windows gone, the stale name is still canonicalized. This is the case the
    /// self-heal exists for.
    @Test func reconcileStillCanonicalizesWhenWindowsAreProvenGone() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db, home: home)
        let promoted = try await promoteScratchWithTerminals(db: db, router: router, home: home)

        let canonical = TmuxManager.serverName(forRepoPath: promoted.dest)
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(dryRun: true, dryRunWindowIsDead: { _ in true }),
            hooks: HookResolver())
        try await lifecycle.reconcile(
            repoID: promoted.repoID, actuationLog: makeTestActuationLog(),
            reapSharedScratchTmuxResources: true)

        let mainAfter = try #require(try await db.worktrees.get(id: promoted.mainWorktree.id))
        #expect(
            mainAfter.tmuxServer == canonical,
            "a genuinely stale server must still be canonicalized")
    }

    /// Register a plain git repo through the real `repo.add` RPC, giving the
    /// harness a surviving repo whose reconcile can janitor shared servers
    /// after the promoted repo itself is removed.
    private func addSurvivorRepo(router: RPCRouter, home: URL) async throws -> Repo {
        let dir = home.appendingPathComponent("projects/survivor-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try gitInitCommit(at: dir)
        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.repoAdd, params: RepoAddParams(path: dir)))
        return try resp.decodeResult(Repo.self)
    }

    /// The reachable trigger for "nothing references the inherited server
    /// anymore" is REMOVING the promoted repo: `repo.remove` hard-deletes its
    /// main worktree row via `deleteForRepo` (a `.main` row can never be
    /// merely archived — `WorktreeStore.archive` refuses `.main`). That row
    /// was the only repo-side pointer to the inherited scratch server, so
    /// afterwards only the retired scratch row (repoID nil, archived) still
    /// references it — and scratch rows belong to no repo, so no per-repo
    /// reconcile visited that server before scratch-referenced servers were
    /// folded into every reconcile's visit set. With nothing live on the
    /// server anywhere, the next reconcile of ANY surviving repo must kill it.
    @Test func reconcileKillsInheritedServerOnceNothingReferencesIt() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db, home: home)
        let promoted = try await promoteScratchWithTerminals(db: db, router: router, home: home)

        let removeResp = await router.handle(try RPCRequest(
            method: RPCMethod.repoRemove,
            params: RepoRemoveParams(repoID: promoted.repoID, force: false)))
        #expect(removeResp.success)
        // Hard-deleted, not archived: no row of any repo references the
        // inherited server anymore.
        #expect(try await db.worktrees.list(repoID: promoted.repoID).isEmpty)

        let survivor = try await addSurvivorRepo(router: router, home: home)

        let recorder = RecordedTmux()
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(),
            tmux: TmuxManager(dryRun: true, dryRunRecorder: { recorder.append($0) }),
            hooks: HookResolver())
        try await lifecycle.reconcile(repoID: survivor.id, actuationLog: makeTestActuationLog(), reapSharedScratchTmuxResources: true)

        let serverKills = recorder.snapshot().filter { $0.contains("kill-server") }
        #expect(serverKills.contains { $0.contains(promoted.scratch.tmuxServer) },
                "the inherited scratch server must be killed once no live worktree row references it")
    }

    /// The scratch server is SHARED: every scratch space (and every promoted
    /// repo's main worktree) runs on the one server derived from the scratch
    /// base dir. After the promoted repo is removed through the real flow
    /// (`repo.remove` hard-deletes the main worktree row), its windows linger
    /// untracked on that server while another scratch space is still live on
    /// it. The next reconcile of a surviving repo must sweep only the
    /// untracked windows and leave the server — and the other space's live
    /// window — alone.
    @Test func reconcileSweepsRemovedPromotedRepoWindowsButSparesSharedScratchServer() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db, home: home)
        let promoted = try await promoteScratchWithTerminals(db: db, router: router, home: home)

        // A second scratch space, still live on the same shared server.
        let created = await router.handle(try RPCRequest(
            method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: nil)))
        let otherScratch = try created.decodeResult(Worktree.self)
        // The scratch.create RPC now auto-spawns a default primary agent terminal;
        // clear it so this test controls its own terminal fixture.
        try await db.terminals.deleteForWorktree(worktreeID: otherScratch.id)
        #expect(otherScratch.tmuxServer == promoted.scratch.tmuxServer,
                "sanity: scratch spaces share one tmux server")
        let liveTerminal = try await db.terminals.create(
            worktreeID: otherScratch.id, tmuxWindowID: "@9", tmuxPaneID: "%9",
            label: "shell", kind: .shell)

        // Real trigger: remove the promoted repo; its main worktree row (and
        // with it the tracking for windows @1/@2) is hard-deleted.
        let removeResp = await router.handle(try RPCRequest(
            method: RPCMethod.repoRemove,
            params: RepoRemoveParams(repoID: promoted.repoID, force: false)))
        #expect(removeResp.success)

        let survivor = try await addSurvivorRepo(router: router, home: home)

        let scratchServer = promoted.scratch.tmuxServer
        let recorder = RecordedTmux()
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(),
            tmux: TmuxManager(
                dryRun: true,
                dryRunRecorder: { recorder.append($0) },
                dryRunListWindows: { server, _ in
                    server == scratchServer
                        ? [(windowID: "@1", paneID: "%1"),
                           (windowID: "@2", paneID: "%2"),
                           (windowID: "@9", paneID: "%9")]
                        : []
                }),
            hooks: HookResolver())
        try await lifecycle.reconcile(repoID: survivor.id, actuationLog: makeTestActuationLog(), reapSharedScratchTmuxResources: true)

        let cmds = recorder.snapshot()
        #expect(!cmds.contains { $0.contains("kill-server") && $0.contains(scratchServer) },
                "a shared server still referenced by a live scratch space must survive")
        let windowKills = cmds.filter { $0.contains("kill-window") }
        #expect(windowKills.contains { $0.contains("@1") && $0.contains(scratchServer) },
                "the removed promoted repo's orphaned windows must be swept")
        #expect(windowKills.contains { $0.contains("@2") })
        #expect(!windowKills.contains { $0.contains("@9") },
                "the live scratch space's tracked window must be spared")
        // And the live scratch space's terminal row is untouched.
        #expect(try await db.terminals.get(id: liveTerminal.id) != nil)
    }

    @Test func reconcileStillCanonicalizesWhenStoredServerHasNoLiveWindows() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db, home: home)
        let promoted = try await promoteScratchWithTerminals(db: db, router: router, home: home)

        // Every window dead — the genuinely-stale case the self-heal was
        // built for: reconcile must canonicalize the server name, park the
        // resumable Claude terminal, and delete the shell row.
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(),
            tmux: TmuxManager(dryRun: true, dryRunWindowIsDead: { _ in true }),
            hooks: HookResolver())
        try await lifecycle.reconcile(repoID: promoted.repoID, actuationLog: makeTestActuationLog(), reapSharedScratchTmuxResources: true)

        let canonical = TmuxManager.serverName(forRepoPath: promoted.dest)
        let mainAfter = try #require(try await db.worktrees.get(id: promoted.mainWorktree.id))
        #expect(mainAfter.tmuxServer == canonical)

        let claudeAfter = try #require(try await db.terminals.get(id: promoted.claude.id))
        #expect(claudeAfter.hibernatedAt != nil)          // parked, session preserved
        #expect(claudeAfter.claudeSessionID == "sess-1")
        #expect(try await db.terminals.get(id: promoted.shell.id) == nil)  // nothing to preserve
    }

    /// Thread-safe collector for TmuxManager dryRun recorded argv.
    private final class RecordedTmux: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [[String]] = []

        func append(_ args: [String]) {
            lock.lock(); defer { lock.unlock() }
            commands.append(args)
        }

        func snapshot() -> [[String]] {
            lock.lock(); defer { lock.unlock() }
            return commands
        }
    }
}

}
