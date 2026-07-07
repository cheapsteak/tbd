import Testing
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
        setenv("TBD_HOME", home.path, 1)
        setenv("TBD_CLAUDE_HOST_HOME", home.appendingPathComponent("claude-host").path, 1)
        return (home, {
            unsetenv("TBD_HOME")
            unsetenv("TBD_CLAUDE_HOST_HOME")
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
            )
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
        try gitInitCommit(at: wt.path)

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
        try await lifecycle.reconcile(repoID: promoted.repoID)

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

    /// After the promoted main worktree is archived, its row is the only
    /// remaining pointer to the inherited scratch server. With nothing live
    /// referencing that server anywhere (the scratch row was archived by the
    /// promote itself), reconcile's cleanup pass must kill it — before this,
    /// the pass only ever considered the canonical per-repo server, so the
    /// inherited server lingered forever.
    @Test func reconcileKillsInheritedServerOnceNothingReferencesIt() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db, home: home)
        let promoted = try await promoteScratchWithTerminals(db: db, router: router, home: home)

        try await db.worktrees.updateStatus(id: promoted.mainWorktree.id, status: .archived)

        let recorder = RecordedTmux()
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(),
            tmux: TmuxManager(dryRun: true, dryRunRecorder: { recorder.append($0) }),
            hooks: HookResolver())
        try await lifecycle.reconcile(repoID: promoted.repoID)

        let serverKills = recorder.snapshot().filter { $0.contains("kill-server") }
        #expect(serverKills.contains { $0.contains(promoted.scratch.tmuxServer) },
                "the inherited scratch server must be killed once no live worktree row references it")
    }

    /// The scratch server is SHARED: every scratch space (and every promoted
    /// repo's main worktree) runs on the one server derived from the scratch
    /// base dir. When the archived promoted main's windows linger there but
    /// another scratch space is still live on it, reconcile must sweep only
    /// the untracked windows and leave the server — and the other space's
    /// live window — alone.
    @Test func reconcileSweepsArchivedMainWindowsButSparesSharedScratchServer() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db, home: home)
        let promoted = try await promoteScratchWithTerminals(db: db, router: router, home: home)

        // A second scratch space, still live on the same shared server.
        let created = await router.handle(try RPCRequest(
            method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: nil)))
        let otherScratch = try created.decodeResult(Worktree.self)
        #expect(otherScratch.tmuxServer == promoted.scratch.tmuxServer,
                "sanity: scratch spaces share one tmux server")
        let liveTerminal = try await db.terminals.create(
            worktreeID: otherScratch.id, tmuxWindowID: "@9", tmuxPaneID: "%9",
            label: "shell", kind: .shell)

        try await db.worktrees.updateStatus(id: promoted.mainWorktree.id, status: .archived)

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
        try await lifecycle.reconcile(repoID: promoted.repoID)

        let cmds = recorder.snapshot()
        #expect(!cmds.contains { $0.contains("kill-server") && $0.contains(scratchServer) },
                "a shared server still referenced by a live scratch space must survive")
        let windowKills = cmds.filter { $0.contains("kill-window") }
        #expect(windowKills.contains { $0.contains("@1") && $0.contains(scratchServer) },
                "the archived promoted main's orphaned windows must be swept")
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
        try await lifecycle.reconcile(repoID: promoted.repoID)

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
