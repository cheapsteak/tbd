import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Regression tests for the bug where recreated tmux panes inherited a stale
/// `TBD_WORKTREE_ID` from their tmux server's global env, mis-routing
/// notifications from sub-worktrees to the main worktree.
///
/// Two surfaces are covered:
///  1. `Daemon.scrubInheritedTBDEnv()` clears poisoning vars from the daemon's
///     own env before any tmux server is spawned.
///  2. The recreate paths (`recreateAfterReboot` and `handleTerminalRecreateWindow`)
///     defensively set `TBD_WORKTREE_ID` on every new pane so they don't
///     inherit a stale value from the tmux server's global environment.

// MARK: - Recorder helper (mirrors LifecycleRecordedCommands in WorktreeLifecycleTests)

private final class RecordedCommands: @unchecked Sendable {
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

/// Returns the shell command body (last argument of `new-window`) for any
/// recorded `new-window` invocation. tmux argv ends with `<shell> -ic <body>`
/// when env vars are inlined, so the body is the last element.
private func newWindowBodies(_ recorded: [[String]]) -> [String] {
    recorded.compactMap { call in
        guard call.contains("new-window") else { return nil }
        return call.last
    }
}

// MARK: - Fix 1: Daemon scrubInheritedTBDEnv

@Test("Daemon.scrubInheritedTBDEnv clears all four TBD_* vars")
func testScrubInheritedTBDEnv() {
    // Seed sentinel values for all four vars.
    setenv("TBD_WORKTREE_ID", "leaked-worktree-id", 1)
    setenv("TBD_PROMPT_CONTEXT", "leaked-context", 1)
    setenv("TBD_PROMPT_INSTRUCTIONS", "leaked-instructions", 1)
    setenv("TBD_PROMPT_RENAME", "leaked-rename", 1)

    // Sanity: setenv worked.
    #expect(ProcessInfo.processInfo.environment["TBD_WORKTREE_ID"] == "leaked-worktree-id")

    Daemon.scrubInheritedTBDEnv()

    #expect(ProcessInfo.processInfo.environment["TBD_WORKTREE_ID"] == nil)
    #expect(ProcessInfo.processInfo.environment["TBD_PROMPT_CONTEXT"] == nil)
    #expect(ProcessInfo.processInfo.environment["TBD_PROMPT_INSTRUCTIONS"] == nil)
    #expect(ProcessInfo.processInfo.environment["TBD_PROMPT_RENAME"] == nil)
}

// MARK: - Fix 2a: recreateAfterReboot sets TBD_WORKTREE_ID on every branch

/// Drive `recreateAfterReboot` for a Claude terminal (has `claudeSessionID`).
/// Assert the captured shell command exports the correct worktree UUID.
@Test("recreateAfterReboot — claude branch sets TBD_WORKTREE_ID")
func testRecreateAfterRebootClaudeBranchSetsWorktreeID() async throws {
    let db = try TBDDatabase(inMemory: true)
    let recorded = RecordedCommands()
    let tmux = TmuxManager(dryRun: true, dryRunRecorder: { args in
        recorded.append(args)
    })
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: tmux,
        hooks: HookResolver()
    )

    // Seed a repo + worktree + claude terminal directly in the DB so we can
    // call recreateAfterReboot without driving full reconcile.
    let repo = try await db.repos.create(
        path: "/tmp/fake-repo", displayName: "test", defaultBranch: "main"
    )
    let wt = try await db.worktrees.create(
        repoID: repo.id,
        name: "wt-claude",
        branch: "tbd/wt-claude",
        path: "/tmp/fake-repo/wt-claude",
        tmuxServer: "tbd-deadbeef"
    )
    let terminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "@stale",
        tmuxPaneID: "%stale",
        label: "Claude",
        claudeSessionID: "session-abc-123"
    )

    try await lifecycle.recreateAfterReboot(terminal: terminal, worktree: wt)

    let bodies = newWindowBodies(recorded.snapshot())
    #expect(!bodies.isEmpty, "expected at least one new-window invocation")
    let expected = "export TBD_WORKTREE_ID='\(wt.id.uuidString)';"
    #expect(bodies.contains { $0.contains(expected) },
            "claude-branch recreation must export TBD_WORKTREE_ID; got bodies: \(bodies)")
}

@Test("recreateAfterReboot — codex branch sets TBD_WORKTREE_ID")
func testRecreateAfterRebootCodexBranchSetsWorktreeID() async throws {
    let db = try TBDDatabase(inMemory: true)
    let recorded = RecordedCommands()
    let tmux = TmuxManager(dryRun: true, dryRunRecorder: { args in
        recorded.append(args)
    })
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: tmux,
        hooks: HookResolver()
    )

    let repo = try await db.repos.create(
        path: "/tmp/fake-repo-codex", displayName: "test", defaultBranch: "main"
    )
    let wt = try await db.worktrees.create(
        repoID: repo.id,
        name: "wt-codex",
        branch: "tbd/wt-codex",
        path: "/tmp/fake-repo-codex/wt-codex",
        tmuxServer: "tbd-cafebabe"
    )
    // Codex branch is detected by label == "Codex" with no claudeSessionID.
    let terminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "@stale-codex",
        tmuxPaneID: "%stale-codex",
        label: "Codex",
        claudeSessionID: nil
    )

    try await lifecycle.recreateAfterReboot(terminal: terminal, worktree: wt)

    let bodies = newWindowBodies(recorded.snapshot())
    let expected = "export TBD_WORKTREE_ID='\(wt.id.uuidString)';"
    #expect(bodies.contains { $0.contains(expected) },
            "codex-branch recreation must export TBD_WORKTREE_ID; got bodies: \(bodies)")
    // CODEX_HOME should still be exported alongside (regression guard).
    #expect(bodies.contains { $0.contains("export CODEX_HOME=") },
            "codex-branch must still export CODEX_HOME; got bodies: \(bodies)")
}

@Test("recreateAfterReboot — shell branch sets TBD_WORKTREE_ID")
func testRecreateAfterRebootShellBranchSetsWorktreeID() async throws {
    let db = try TBDDatabase(inMemory: true)
    let recorded = RecordedCommands()
    let tmux = TmuxManager(dryRun: true, dryRunRecorder: { args in
        recorded.append(args)
    })
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: tmux,
        hooks: HookResolver()
    )

    let repo = try await db.repos.create(
        path: "/tmp/fake-repo-shell", displayName: "test", defaultBranch: "main"
    )
    let wt = try await db.worktrees.create(
        repoID: repo.id,
        name: "wt-shell",
        branch: "tbd/wt-shell",
        path: "/tmp/fake-repo-shell/wt-shell",
        tmuxServer: "tbd-feedface"
    )
    // Shell branch: label is "shell" (or nil), no claudeSessionID, not "Codex".
    let terminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "@stale-sh",
        tmuxPaneID: "%stale-sh",
        label: "shell",
        claudeSessionID: nil
    )

    try await lifecycle.recreateAfterReboot(terminal: terminal, worktree: wt)

    let bodies = newWindowBodies(recorded.snapshot())
    let expected = "export TBD_WORKTREE_ID='\(wt.id.uuidString)';"
    #expect(bodies.contains { $0.contains(expected) },
            "shell-branch recreation must export TBD_WORKTREE_ID; got bodies: \(bodies)")
}

// MARK: - Fix 2b: handleTerminalRecreateWindow sets TBD_WORKTREE_ID

@Test("handleTerminalRecreateWindow sets TBD_WORKTREE_ID on the recreated pane")
func testHandleTerminalRecreateWindowSetsWorktreeID() async throws {
    let db = try TBDDatabase(inMemory: true)
    let recorded = RecordedCommands()
    let tmux = TmuxManager(dryRun: true, dryRunRecorder: { args in
        recorded.append(args)
    })
    let router = RPCRouter(
        db: db,
        lifecycle: WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: tmux,
            hooks: HookResolver()
        ),
        tmux: tmux
    )

    let repo = try await db.repos.create(
        path: "/tmp/fake-repo-recreate", displayName: "test", defaultBranch: "main"
    )
    let wt = try await db.worktrees.create(
        repoID: repo.id,
        name: "wt-recreate",
        branch: "tbd/wt-recreate",
        path: "/tmp/fake-repo-recreate/wt-recreate",
        tmuxServer: "tbd-12345678"
    )
    let terminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "@old",
        tmuxPaneID: "%old",
        label: "shell"
    )

    let request = try RPCRequest(
        method: RPCMethod.terminalRecreateWindow,
        params: TerminalRecreateWindowParams(terminalID: terminal.id)
    )
    let response = await router.handle(request)
    #expect(response.success, "expected success; error: \(response.error ?? "nil")")

    let bodies = newWindowBodies(recorded.snapshot())
    let expected = "export TBD_WORKTREE_ID='\(wt.id.uuidString)';"
    #expect(bodies.contains { $0.contains(expected) },
            "handleTerminalRecreateWindow must export TBD_WORKTREE_ID; got bodies: \(bodies)")
}

// MARK: - Regression: handleTerminalCreate still sets TBD_WORKTREE_ID

@Test("handleTerminalCreate (regression) still exports the correct TBD_WORKTREE_ID")
func testHandleTerminalCreateRegressionWorktreeID() async throws {
    let db = try TBDDatabase(inMemory: true)
    let recorded = RecordedCommands()
    let tmux = TmuxManager(dryRun: true, dryRunRecorder: { args in
        recorded.append(args)
    })
    let router = RPCRouter(
        db: db,
        lifecycle: WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: tmux,
            hooks: HookResolver()
        ),
        tmux: tmux
    )

    let repo = try await db.repos.create(
        path: "/tmp/fake-repo-create", displayName: "test", defaultBranch: "main"
    )
    let wt = try await db.worktrees.create(
        repoID: repo.id,
        name: "wt-create",
        branch: "tbd/wt-create",
        path: "/tmp/fake-repo-create/wt-create",
        tmuxServer: "tbd-87654321"
    )

    // type: .shell exercises the simple non-claude, non-codex path.
    let request = try RPCRequest(
        method: RPCMethod.terminalCreate,
        params: TerminalCreateParams(worktreeID: wt.id, type: .shell)
    )
    let response = await router.handle(request)
    #expect(response.success, "expected success; error: \(response.error ?? "nil")")

    let bodies = newWindowBodies(recorded.snapshot())
    let expected = "export TBD_WORKTREE_ID='\(wt.id.uuidString)';"
    #expect(bodies.contains { $0.contains(expected) },
            "handleTerminalCreate must export TBD_WORKTREE_ID matching params.worktreeID; got bodies: \(bodies)")
}
