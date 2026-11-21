import Testing
import DaemonTestSupport
import TestSupport
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

// Nested under TBDHomeSerialized: scratch.create resolves
// TBDConstants.scratchDir from the process-global TBD_HOME, and
// TBD_CLAUDE_HOST_HOME keeps the ambient projects root off the developer's
// real ~/.claude. See TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {

/// Regression suite for the promote → reconcile interaction: a promoted-main
/// worktree deliberately keeps the scratch tmux server its sessions ran on, so
/// reconcile must judge its tmux rows by THAT server, the one the row stores,
/// never by the canonical name for the promoted repo's path. Asking the
/// canonical server, which has never run, would read every session as gone
/// and park or delete rows whose sessions may still be running.
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

    /// Spawns go through the holder spawn double, wired into both the router
    /// and the lifecycle it copies, so `scratch.create` opens its primary
    /// terminal as the daemon does.
    private func makeRouter(_ db: TBDDatabase, home: URL) -> RPCRouter {
        let registry = makeHolderRegistryDouble(launch: FakeHolderLaunch())
        var lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver(),
            leftoverTmuxProbe: .absent)
        lifecycle.holderRegistry = registry
        let router = RPCRouter(
            db: db,
            lifecycle: lifecycle,
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            configDirManager: ClaudeProfileConfigDirManager(
                baseDirectory: home.appendingPathComponent("profiles", isDirectory: true),
                hostBaseDirectory: home.appendingPathComponent("claude-host", isDirectory: true)
            ),
            actuationLog: makeTestActuationLog()
        )
        router.holderRegistry = registry
        return router
    }

    /// Makes `path` a repo with one empty commit, so promote's `hasCommits`
    /// guard passes and `repo.add` accepts it. `initTestRepo` copies a template
    /// built once per process through the hermetic `shell`, so only the first
    /// call in a process waits on a child, and a failed setup throws instead of
    /// passing silently.
    private func gitInitCommit(at path: String) async throws {
        try await initTestRepo(at: URL(fileURLWithPath: path))
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
        try await gitInitCommit(at: wt.localPath)
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

    @Test func reconcileKeepsInheritedServerAndTerminalsWhileItMayStillRun() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db, home: home)
        let promoted = try await promoteScratchWithTerminals(db: db, router: router, home: home)

        // Sanity: the inherited scratch server is NOT the canonical name for
        // the promoted repo path — otherwise this test proves nothing.
        let canonical = TmuxServerName.forRepoPath(promoted.dest)
        #expect(promoted.mainWorktree.tmuxServer != canonical)
        #expect(promoted.mainWorktree.tmuxServer == promoted.scratch.tmuxServer)

        // The inherited server may still be running: reconcile must leave it
        // and its rows alone.
        let probe = RecordingLeftoverTmuxProbe(answer: { server in
            server == canonical ? .absent : .running
        })
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver(),
            leftoverTmuxProbe: probe.probe)
        try await lifecycle.reconcile(repoID: promoted.repoID, actuationLog: makeTestActuationLog())

        #expect(probe.servers == [promoted.scratch.tmuxServer],
                "reconcile probed a server the rows do not store: \(probe.servers)")
        // The stored server name is never rewritten.
        let mainAfter = try #require(try await db.worktrees.get(id: promoted.mainWorktree.id))
        #expect(mainAfter.tmuxServer == promoted.scratch.tmuxServer)

        // Terminal rows intact: nothing parked, nothing deleted.
        let terminals = try await db.terminals.list(worktreeID: promoted.mainWorktree.id)
        #expect(Set(terminals.map(\.id)) == [promoted.claude.id, promoted.shell.id])
        let claudeAfter = try #require(terminals.first(where: { $0.id == promoted.claude.id }))
        #expect(claudeAfter.hibernatedAt == nil)
        #expect(claudeAfter.suspendedAt == nil)
    }

    @Test func reconcileParksAndDeletesOnceTheInheritedServerIsGone() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db, home: home)
        let promoted = try await promoteScratchWithTerminals(db: db, router: router, home: home)

        // The inherited server is gone: reconcile must park the resumable
        // Claude terminal and delete the shell row, and still leave the stored
        // server name as it was.
        let canonical = TmuxServerName.forRepoPath(promoted.dest)
        let probe = RecordingLeftoverTmuxProbe(answer: { server in
            server == canonical ? .running : .absent
        })
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver(),
            leftoverTmuxProbe: probe.probe)
        try await lifecycle.reconcile(repoID: promoted.repoID, actuationLog: makeTestActuationLog())

        let mainAfter = try #require(try await db.worktrees.get(id: promoted.mainWorktree.id))
        #expect(mainAfter.tmuxServer == promoted.scratch.tmuxServer)

        let claudeAfter = try #require(try await db.terminals.get(id: promoted.claude.id))
        #expect(claudeAfter.hibernatedAt != nil)          // parked, session preserved
        #expect(claudeAfter.claudeSessionID == "sess-1")
        #expect(try await db.terminals.get(id: promoted.shell.id) == nil)  // nothing to preserve
    }
}

}
