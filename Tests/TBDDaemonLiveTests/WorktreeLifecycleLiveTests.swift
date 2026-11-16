import Foundation
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Tier 3 (docs/specs/2026-07-24-test-hardening-design.md §3): the reconcile
// test below builds a REAL-mode `TmuxManager` and calls `ensureServer`, so it
// starts an actual tmux server on a unique socket. That external process is
// what makes it tier 3 — the rest of `WorktreeLifecycleTests` stays in
// `TBDDaemonTests` because it injects the leftover-tmux probe and touches
// nothing outside the process.

/// A tmux server an earlier build started, judged end to end through
/// `reconcile(repoID:)` and the production socket probe
/// (`LeftoverTmuxServerProbe`), against a real tmux server's real socket.
///
/// While the server runs, reconcile leaves its rows live: TBD can neither
/// reach nor stop those sessions. Once the server is gone (a reboot, or
/// `tmux kill-server`), the rows are PARKED (resumable Claude) or deleted
/// (plain shell) — never recreated, and the dead server stays dead (#284).
///
/// This is the one test that proves the probe's socket path is where tmux
/// really puts its socket: the daemon and the tmux client share an
/// environment, so both resolve `TMUX_TMPDIR` the same way.
@Test func testReconcileRebootParksClaudeAndDeletesShell() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let realTmux = TmuxManager()
    // The production probe, as the daemon builds it.
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(), tmux: realTmux, hooks: HookResolver()
    )

    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "acme", defaultBranch: "main"
    )
    let serverName = TmuxManager.serverName(forRepoPath: repo.path)

    // A worktree whose path == the repo path is reported by `git worktree
    // list`, so reconcile will not archive it as missing.
    let wt = try await db.worktrees.create(
        repoID: repo.id, name: "wt", branch: "main",
        path: repoDir.path, tmuxServer: serverName
    )

    // Start a real server + two real windows, recording their actual IDs so the
    // terminal rows look exactly like a session an earlier build left running.
    _ = try await realTmux.ensureServer(server: serverName, session: "main", cwd: repoDir.path)
    let claudeWindow = try await realTmux.createWindow(
        server: serverName, session: "main", cwd: repoDir.path, shellCommand: "sleep 60"
    )
    let shellWindow = try await realTmux.createWindow(
        server: serverName, session: "main", cwd: repoDir.path, shellCommand: "sleep 60"
    )

    let sessionID = UUID().uuidString
    let claudeTerminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: claudeWindow.windowID, tmuxPaneID: claudeWindow.paneID,
        label: "claude", claudeSessionID: sessionID, kind: .claude
    )
    let shellTerminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: shellWindow.windowID, tmuxPaneID: shellWindow.paneID
    )

    // The server is running: both rows stay live and untouched.
    do {
        try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog())
    } catch {
        try? await realTmux.killServer(server: serverName)
        throw error
    }
    let claudeWhileRunning = try await db.terminals.get(id: claudeTerminal.id)
    let shellWhileRunning = try await db.terminals.get(id: shellTerminal.id)
    #expect(claudeWhileRunning?.isParked == false,
            "a session whose tmux server is running must not be parked")
    #expect(shellWhileRunning != nil,
            "a shell whose tmux server is running must not be deleted")

    // Simulate the reboot: the whole server is gone. tmux leaves its socket
    // file behind, so the probe reads a refused connect, not a missing path.
    try await realTmux.killServer(server: serverName)
    let aliveAfterKill = await realTmux.serverExists(server: serverName)
    #expect(!aliveAfterKill, "precondition: server must be gone to model a reboot")

    do {
        try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog())
    } catch {
        try? await realTmux.killServer(server: serverName)
        throw error
    }

    let claudeAfter = try await db.terminals.get(id: claudeTerminal.id)
    let shellAfter = try await db.terminals.get(id: shellTerminal.id)
    // Was the dead server resurrected by an eager recreate? (The bug.)
    let serverAliveAfter = await realTmux.serverExists(server: serverName)
    try? await realTmux.killServer(server: serverName)

    // Resumable Claude session: parked, not recreated, not deleted.
    #expect(claudeAfter != nil, "claude terminal must NOT be deleted on reboot")
    #expect(claudeAfter?.isParked == true, "claude terminal must be parked (resumable via wake)")
    #expect(claudeAfter?.hibernateReason == .recovery)
    #expect(claudeAfter?.claudeSessionID == sessionID, "session ID must be preserved for on-demand resume")
    #expect(claudeAfter?.tmuxWindowID == claudeWindow.windowID,
            "reboot must not recreate the claude window (no eager `claude --resume`)")

    // Plain shell: nothing resumable, deleted.
    #expect(shellAfter == nil, "shell terminal with no session must be deleted on reboot")

    // CRUCIAL #284 invariant: reconcile must not have bootstrapped the dead
    // server to recreate windows. No mass `claude --resume` storm on reboot.
    #expect(!serverAliveAfter,
            "reconcile must leave the dead server dead — no eager mass-recreate (#284)")
}
