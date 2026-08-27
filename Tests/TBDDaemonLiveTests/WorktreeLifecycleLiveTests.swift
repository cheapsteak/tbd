import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Tier 3 (docs/specs/2026-07-24-test-hardening-design.md §3): the five
// reconcile tests below build a REAL-mode `TmuxManager` and call `ensureServer`,
// so each one starts an actual tmux server on a unique socket. That external
// process is what makes them tier 3 — the rest of `WorktreeLifecycleTests`
// stays in `TBDDaemonTests` because it runs against `TmuxManager(dryRun: true)`
// and touches nothing outside the process.

/// Reboot path (whole tmux server gone) driven end-to-end through
/// `reconcile(repoID:)`, against a real tmux. Proves the #284 fix: terminals
/// are PARKED as suspended (resumable Claude) or deleted (plain shell) — NOT
/// eagerly recreated. Recovery is the on-demand Resume button (see #285), so
/// reconcile must leave the dead server dead.
///
/// This needs a REAL `TmuxManager`: `TmuxManager(dryRun: true)` always reports
/// the server `.present`, so it cannot model the post-reboot state this test
/// depends on. We start a real server, capture live window/pane IDs, then kill
/// the server to simulate the reboot.
///
/// **Why the process probe is injected rather than left to run for real.**
/// `serverPresence` may only answer `.absent` for a server that did not respond
/// when no tmux server process exists for this uid at all — tmux itself cannot
/// tell "gone" from "this process resolved a different socket", and the process
/// table is the only place that distinction exists. A reboot makes that
/// condition true; a test cannot. This suite starts real tmux servers of its
/// own, sibling worktrees on a shared box run more, and CI runners are not
/// guaranteed bare either, so a real probe here would answer "yes, tmux is
/// running" for reasons that have nothing to do with the server under test and
/// the assertion would flip with the machine's mood. `tmuxServerProcessProbe`
/// pins it to the post-reboot fact — no tmux process anywhere — while every
/// other step, including the kill and the `list-sessions` that fails after it,
/// stays real. The probe's own three branches are pinned deterministically in
/// `TBDDaemonTests/TmuxServerPresenceTests`.
@Test func testReconcileRebootParksClaudeAndDeletesShell() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let realTmux = TmuxManager(tmuxServerProcessProbe: { false })
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(), tmux: realTmux, hooks: HookResolver()
    )

    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )
    // reconcile derives the server name from the repo path, so the worktree row
    // must use the same name for the serverPresence probe to match.
    let serverName = TmuxManager.serverName(forRepoPath: repo.path)

    // A worktree whose path == the repo path is reported by `git worktree
    // list`, so reconcile will not archive it as missing.
    let wt = try await db.worktrees.create(
        repoID: repo.id, name: "wt", branch: "main",
        path: repoDir.path, tmuxServer: serverName
    )

    // Start a real server + two real windows, recording their actual IDs so the
    // terminal rows look exactly like a pre-reboot live state.
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

    // Simulate the reboot: the whole server is gone. `list-sessions` really
    // fails; the pinned probe supplies the out-of-tmux half — no tmux server
    // process exists — which is what makes the verdict `.absent` rather than
    // the row-protecting `.unreachable`.
    try await realTmux.killServer(server: serverName)
    let presenceAfterKill = await realTmux.serverPresence(server: serverName)
    #expect(presenceAfterKill == .absent,
            "precondition: a killed server with no tmux process left must read as absent")

    do {
        try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog(), reapSharedScratchTmuxResources: true)
    } catch {
        try? await realTmux.killServer(server: serverName)
        throw error
    }

    let claudeAfter = try await db.terminals.get(id: claudeTerminal.id)
    let shellAfter = try await db.terminals.get(id: shellTerminal.id)
    // Was the dead server resurrected by an eager recreate? (The bug.)
    let serverPresenceAfter = await realTmux.serverPresence(server: serverName)
    try? await realTmux.killServer(server: serverName)

    // Resumable Claude session: parked, not recreated, not deleted.
    #expect(claudeAfter != nil, "claude terminal must NOT be deleted on reboot")
    #expect(claudeAfter?.isParked == true, "claude terminal must be parked (resumable via wake)")
    #expect(claudeAfter?.claudeSessionID == sessionID,
            "session ID must be preserved for on-demand resume")
    // The window/pane IDs must NOT have been replaced — reconcile does not spawn
    // a new window on the reboot path anymore.
    #expect(claudeAfter?.tmuxWindowID == claudeWindow.windowID,
            "reboot must not recreate the claude window (no eager `claude --resume`)")

    // Plain shell: nothing resumable, deleted.
    #expect(shellAfter == nil, "shell terminal with no session must be deleted on reboot")

    // CRUCIAL #284 invariant: reconcile must not have bootstrapped the dead
    // server to recreate windows. No mass `claude --resume` storm on reboot.
    #expect(serverPresenceAfter != .present,
            "reconcile must leave the dead server dead — no eager mass-recreate (#284)")
}

/// Dead-window cleanup, real tmux server alive: a terminal that holds a
/// `claudeSessionID` must be SUSPENDED (not deleted) so the session can be
/// resumed. Regression test for the 2026-05-21 mass session-loss incident.
@Test func testReconcileDeadWindowClaudeTerminalSuspended() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let realTmux = TmuxManager()
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(), tmux: realTmux, hooks: HookResolver()
    )

    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )
    let serverName = TmuxManager.serverName(forRepoPath: repo.path)
    // Start a REAL tmux server so reconcile sees serverAlive == true.
    _ = try await realTmux.ensureServer(server: serverName, session: "main", cwd: repoDir.path)

    // A worktree whose path == the repo path is reported by `git worktree
    // list`, so reconcile will not archive it as missing.
    let wt = try await db.worktrees.create(
        repoID: repo.id, name: "wt", branch: "main",
        path: repoDir.path, tmuxServer: serverName
    )
    // A claude terminal pointing at a window that does not exist on the server.
    let sessionID = UUID().uuidString
    let terminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "@stale-claude", tmuxPaneID: "%stale-claude",
        label: "claude", claudeSessionID: sessionID, kind: .claude
    )

    do {
        try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog(), reapSharedScratchTmuxResources: true)
    } catch {
        try? await realTmux.killServer(server: serverName)
        throw error
    }

    let after = try await db.terminals.get(id: terminal.id)
    try? await realTmux.killServer(server: serverName)

    #expect(after != nil, "claude terminal must NOT be deleted on dead window")
    #expect(after?.isParked == true, "claude terminal must be parked (resumable via wake)")
    #expect(after?.claudeSessionID == sessionID, "session ID must be preserved")
}

/// Dead-window cleanup, real tmux server alive: a terminal with NO
/// `claudeSessionID` (plain shell) has nothing to recover and is still
/// deleted — unchanged behavior.
@Test func testReconcileDeadWindowShellTerminalDeleted() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let realTmux = TmuxManager()
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(), tmux: realTmux, hooks: HookResolver()
    )

    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )
    let serverName = TmuxManager.serverName(forRepoPath: repo.path)
    _ = try await realTmux.ensureServer(server: serverName, session: "main", cwd: repoDir.path)

    let wt = try await db.worktrees.create(
        repoID: repo.id, name: "wt", branch: "main",
        path: repoDir.path, tmuxServer: serverName
    )
    let terminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "@stale-shell", tmuxPaneID: "%stale-shell"
    )

    do {
        try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog(), reapSharedScratchTmuxResources: true)
    } catch {
        try? await realTmux.killServer(server: serverName)
        throw error
    }

    let after = try await db.terminals.get(id: terminal.id)
    try? await realTmux.killServer(server: serverName)

    #expect(after == nil, "shell terminal with no session must still be deleted")
}

@Test func testReconcileDeadWindowCodexTerminalWithSessionMetadataDeleted() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let realTmux = TmuxManager()
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(), tmux: realTmux, hooks: HookResolver()
    )

    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )
    let serverName = TmuxManager.serverName(forRepoPath: repo.path)
    _ = try await realTmux.ensureServer(server: serverName, session: "main", cwd: repoDir.path)

    let wt = try await db.worktrees.create(
        repoID: repo.id, name: "wt", branch: "main",
        path: repoDir.path, tmuxServer: serverName
    )
    let terminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "@stale-codex", tmuxPaneID: "%stale-codex",
        label: "Codex", claudeSessionID: UUID().uuidString, kind: .codex
    )

    do {
        try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog(), reapSharedScratchTmuxResources: true)
    } catch {
        try? await realTmux.killServer(server: serverName)
        throw error
    }

    let after = try await db.terminals.get(id: terminal.id)
    try? await realTmux.killServer(server: serverName)

    #expect(after == nil, "stale codex terminal must be deleted, not suspended via Claude semantics")
}

@Test("Reconcile: dead window with Claude-resumable terminal parks, not deletes (safety check)")
func testReconcileDeadWindowLiveClaudeNotParked() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)

    // Create a TmuxManager with seams to:
    // 1. Force the window probe to report the test window POSITIVELY absent —
    //    tmux answered on a reachable server — which is the only verdict that
    //    reaches the park path at all
    // 2. Return a Claude version string when paneCurrentCommand is called
    // This simulates the safety check scenario: window reports gone, but
    // Claude process is still running.
    let tmux = TmuxManager(
        realModeWindowPresenceOverride: { server, windowID in
            if windowID == "@live-claude-window" {
                // Simulate a window tmux answered about and does not have.
                return TmuxResourcePresence.absent
            }
            return nil
        },
        realModePaneCurrentCommandOverride: { server, paneID in
            if paneID == "%live-claude-pane" {
                return "2.1.86"  // Return Claude version string (matches isClaudeProcess regex)
            }
            return nil
        }
    )

    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()
    )

    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )
    let serverName = TmuxManager.serverName(forRepoPath: repo.path)
    _ = try await tmux.ensureServer(server: serverName, session: "main", cwd: repoDir.path)

    let wt = try await db.worktrees.create(
        repoID: repo.id, name: "wt", branch: "main",
        path: repoDir.path, tmuxServer: serverName
    )

    let sessionID = UUID().uuidString
    // Create a terminal with the test window/pane IDs that our seams will override
    let terminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "@live-claude-window", tmuxPaneID: "%live-claude-pane",
        label: "claude", claudeSessionID: sessionID, kind: .claude
    )

    do {
        try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog(), reapSharedScratchTmuxResources: true)
    } catch {
        try? await tmux.killServer(server: serverName)
        throw error
    }

    let afterReconcile = try await db.terminals.get(id: terminal.id)
    try? await tmux.killServer(server: serverName)

    // The safety check at WorktreeLifecycle+Reconcile.swift:272-279 should detect
    // that a Claude process is still running in the pane despite the window probe reporting absence.
    // Result: the terminal should NOT be parked (the safety check skips parking).
    #expect(afterReconcile != nil, "Claude terminal must NOT be deleted or parked when live claude is detected")
    #expect(afterReconcile?.isParked == false, "Claude terminal must NOT be parked — the safety check detected live claude process")
    #expect(afterReconcile?.claudeSessionID == sessionID, "Session ID must be preserved")
}
