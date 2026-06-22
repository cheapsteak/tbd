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

private func containsCodexProfileLaunch(_ body: String) -> Bool {
    body.contains("unset CODEX_CI CODEX_THREAD_ID; codex --profile tbd --dangerously-bypass-approvals-and-sandbox")
        || body.contains("unset CODEX_CI CODEX_THREAD_ID; codex --profile-v2 tbd --dangerously-bypass-approvals-and-sandbox")
}

private let codexTestHomePath: String = {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-codex-home-tests-\(UUID().uuidString)", isDirectory: true)
        .path
    setenv("TBD_TEST_CODEX_HOME", path, 1)
    return path
}()

private func installCodexTestHomeOverride() {
    _ = codexTestHomePath
}

// MARK: - Fix 1: Daemon scrubInheritedTBDEnv

@Test("Daemon.scrubInheritedTBDEnv clears inherited routing vars")
func testScrubInheritedTBDEnv() {
    // setenv/unsetenv mutate the shared process environ. Guarantee cleanup
    // even if #expect failures or future edits cause us to skip the scrub
    // call below — Swift Testing runs tests concurrently by default and any
    // future test that reads these vars must not see leaked sentinels.
    defer {
        unsetenv("TBD_WORKTREE_ID")
        unsetenv("TBD_PROMPT_CONTEXT")
        unsetenv("TBD_PROMPT_INSTRUCTIONS")
        unsetenv("TBD_PROMPT_RENAME")
        unsetenv("CODEX_CI")
        unsetenv("CODEX_THREAD_ID")
    }

    setenv("TBD_WORKTREE_ID", "leaked-worktree-id", 1)
    setenv("TBD_PROMPT_CONTEXT", "leaked-context", 1)
    setenv("TBD_PROMPT_INSTRUCTIONS", "leaked-instructions", 1)
    setenv("TBD_PROMPT_RENAME", "leaked-rename", 1)
    setenv("CODEX_CI", "1", 1)
    setenv("CODEX_THREAD_ID", "leaked-thread-id", 1)

    // Sanity: setenv worked.
    #expect(ProcessInfo.processInfo.environment["TBD_WORKTREE_ID"] == "leaked-worktree-id")

    Daemon.scrubInheritedTBDEnv()

    #expect(ProcessInfo.processInfo.environment["TBD_WORKTREE_ID"] == nil)
    #expect(ProcessInfo.processInfo.environment["TBD_PROMPT_CONTEXT"] == nil)
    #expect(ProcessInfo.processInfo.environment["TBD_PROMPT_INSTRUCTIONS"] == nil)
    #expect(ProcessInfo.processInfo.environment["TBD_PROMPT_RENAME"] == nil)
    #expect(ProcessInfo.processInfo.environment["CODEX_CI"] == nil)
    #expect(ProcessInfo.processInfo.environment["CODEX_THREAD_ID"] == nil)
}

// NOTE: The `recreateAfterReboot` env-injection tests were removed alongside the
// function itself (#284). Reconcile no longer recreates windows on reboot — it
// parks resumable terminals as suspended and recovery happens on demand via the
// Resume button (#285). The analogous on-demand recreate path is still covered
// by the `handleTerminalRecreateWindow` tests below.

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

@Test("handleTerminalRecreateWindow uses current Codex launch command")
func testHandleTerminalRecreateWindowCodexLaunchCommand() async throws {
    installCodexTestHomeOverride()
    defer { unsetenv("TBD_TEST_CODEX_HOME") }

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
        path: "/tmp/fake-repo-recreate-codex", displayName: "test", defaultBranch: "main"
    )
    let wt = try await db.worktrees.create(
        repoID: repo.id,
        name: "wt-recreate-codex",
        branch: "tbd/wt-recreate-codex",
        path: "/tmp/fake-repo-recreate-codex/wt-recreate-codex",
        tmuxServer: "tbd-c0de1234"
    )
    let terminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "@old-codex",
        tmuxPaneID: "%old-codex",
        label: "Codex",
        kind: .codex
    )

    let request = try RPCRequest(
        method: RPCMethod.terminalRecreateWindow,
        params: TerminalRecreateWindowParams(terminalID: terminal.id)
    )
    let response = await router.handle(request)
    #expect(response.success, "expected success; error: \(response.error ?? "nil")")

    let bodies = newWindowBodies(recorded.snapshot())
    #expect(bodies.contains {
        containsCodexProfileLaunch($0)
    }, "recreated codex tab must launch codex with the TBD profile; got bodies: \(bodies)")
    #expect(!bodies.contains { $0.contains("codex --full-auto") },
            "recreated codex tab must not use removed --full-auto flag; got bodies: \(bodies)")
}

// MARK: - Dead-window recovery: park resumable Claude terminals instead of wiping to shell

/// When a Claude terminal's tmux window dies under a LIVE app+daemon (sleep/wake
/// or OOM, no daemon restart), `handleTerminalRecreateWindow` must NOT recreate
/// it as a plain shell — that nulls `claudeSessionID`/`transcriptPath` and flips
/// `kind` to `.shell`, destroying the ability to Resume and breaking `/resume`.
/// It must mirror reconcile(): park the terminal as suspended, preserving
/// identity, so the app renders the moon state and offers Resume.
@Test("handleTerminalRecreateWindow parks a resumable Claude terminal as suspended")
func testHandleTerminalRecreateWindowParksClaudeAsSuspended() async throws {
    let db = try TBDDatabase(inMemory: true)
    let tmux = TmuxManager(dryRun: true)
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
        path: "/tmp/fake-repo-recreate-claude", displayName: "test", defaultBranch: "main"
    )
    let wt = try await db.worktrees.create(
        repoID: repo.id,
        name: "wt-recreate-claude",
        branch: "tbd/wt-recreate-claude",
        path: "/tmp/fake-repo-recreate-claude/wt-recreate-claude",
        tmuxServer: "tbd-c1a0de00"
    )
    let sessionID = "11111111-2222-3333-4444-555555555555"
    let transcriptPath = "/tmp/fake-repo-recreate-claude/.claude/projects/foo/\(sessionID).jsonl"
    let terminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "@old-claude",
        tmuxPaneID: "%old-claude",
        label: "claude",
        claudeSessionID: sessionID,
        kind: .claude
    )
    // create() doesn't accept transcriptPath; set it via the SessionStart bridge API.
    try await db.terminals.updateSession(id: terminal.id, sessionID: sessionID, transcriptPath: transcriptPath)

    let request = try RPCRequest(
        method: RPCMethod.terminalRecreateWindow,
        params: TerminalRecreateWindowParams(terminalID: terminal.id)
    )
    let response = await router.handle(request)
    #expect(response.success, "expected success; error: \(response.error ?? "nil")")

    let updated = try #require(try await db.terminals.get(id: terminal.id))
    #expect(updated.suspendedAt != nil, "claude terminal must be parked as suspended, not recreated as shell")
    #expect(updated.kind == .claude, "kind must stay .claude, not flip to .shell")
    #expect(updated.claudeSessionID == sessionID, "claudeSessionID must be preserved")
    #expect(updated.transcriptPath == transcriptPath, "transcriptPath must be preserved")
    #expect(updated.isClaudeResumable, "parked terminal must remain Claude-resumable")
}

/// Regression guard for the OTHER branch: a plain shell terminal whose window
/// died must still be recreated as a plain shell (NOT parked as suspended).
@Test("handleTerminalRecreateWindow rebuilds a shell terminal as a shell")
func testHandleTerminalRecreateWindowRebuildsShellAsShell() async throws {
    let db = try TBDDatabase(inMemory: true)
    let tmux = TmuxManager(dryRun: true)
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
        path: "/tmp/fake-repo-recreate-shell", displayName: "test", defaultBranch: "main"
    )
    let wt = try await db.worktrees.create(
        repoID: repo.id,
        name: "wt-recreate-shell",
        branch: "tbd/wt-recreate-shell",
        path: "/tmp/fake-repo-recreate-shell/wt-recreate-shell",
        tmuxServer: "tbd-5be11000"
    )
    let terminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "@old-shell",
        tmuxPaneID: "%old-shell",
        label: "shell",
        kind: .shell
    )

    let request = try RPCRequest(
        method: RPCMethod.terminalRecreateWindow,
        params: TerminalRecreateWindowParams(terminalID: terminal.id)
    )
    let response = await router.handle(request)
    #expect(response.success, "expected success; error: \(response.error ?? "nil")")

    let updated = try #require(try await db.terminals.get(id: terminal.id))
    #expect(updated.suspendedAt == nil, "shell terminal must not be parked as suspended")
    #expect(updated.kind == .shell, "shell terminal must remain a shell")
    #expect(updated.claudeSessionID == nil, "shell terminal has no session to preserve")
}

// MARK: - Fix 3: setupTerminals injects TBD_TERMINAL_ID + TBD_WORKTREE_ID on the setup tab

/// Regression test for the bug where the auto-created "setup" tab that gets
/// born alongside the Claude tab during `createWorktree` was missing
/// `TBD_WORKTREE_ID` and `TBD_TERMINAL_ID` env vars (the `env:` parameter was
/// defaulting to `[:]`), so the setup hook couldn't identify its owning
/// worktree/terminal.
@Test("createWorktree — setup tab exports TBD_WORKTREE_ID and TBD_TERMINAL_ID")
func testCreateWorktreeSetupTabExportsTBDIDs() async throws {
    // Build a real git repo so completeCreateWorktree can run `git worktree add`.
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-test-\(UUID().uuidString)")
    let repoDir = tempDir.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let initProcess = Process()
    initProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
    initProcess.arguments = ["-c", "git init -b main && git commit --allow-empty -m init"]
    initProcess.currentDirectoryURL = repoDir
    initProcess.environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin",
        "HOME": NSHomeDirectory(),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_AUTHOR_NAME": "Test",
        "GIT_AUTHOR_EMAIL": "test@test.com",
        "GIT_COMMITTER_NAME": "Test",
        "GIT_COMMITTER_EMAIL": "test@test.com",
    ]
    let initPipe = Pipe()
    initProcess.standardOutput = initPipe
    initProcess.standardError = initPipe
    try initProcess.run()
    initProcess.waitUntilExit()
    #expect(initProcess.terminationStatus == 0, "git init failed")

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
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )
    let override = tempDir.appendingPathComponent(".tbd/worktrees").path
    try await db.repos.updateWorktreeRoot(id: repo.id, path: override)
    let resolvedRepo = try await db.repos.get(id: repo.id)!

    // skipClaude: true puts a plain shell in window1 but window2 is still the
    // setup tab — the very thing we're testing here.
    let wt = try await lifecycle.createWorktree(repoID: resolvedRepo.id, skipClaude: true)

    // Two terminals expected: shell + setup
    let terminals = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminals.count == 2, "expected 2 terminals (shell + setup)")
    guard let setup = terminals.first(where: { $0.label == "setup" }) else {
        Issue.record("setup terminal not found; got: \(terminals.map { $0.label ?? "nil" })")
        return
    }

    let bodies = newWindowBodies(recorded.snapshot())
    let expectedWorktree = "export TBD_WORKTREE_ID='\(wt.id.uuidString)';"
    let expectedTerminal = "export TBD_TERMINAL_ID='\(setup.id.uuidString)';"
    #expect(
        bodies.contains { $0.contains(expectedWorktree) && $0.contains(expectedTerminal) },
        "setup tab must export both TBD_WORKTREE_ID and TBD_TERMINAL_ID matching its DB row; got bodies: \(bodies)"
    )
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

@Test("handleTerminalCreate uses current Codex launch command")
func testHandleTerminalCreateCodexLaunchCommand() async throws {
    installCodexTestHomeOverride()
    defer { unsetenv("TBD_TEST_CODEX_HOME") }

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
        path: "/tmp/fake-repo-create-codex", displayName: "test", defaultBranch: "main"
    )
    let wt = try await db.worktrees.create(
        repoID: repo.id,
        name: "wt-create-codex",
        branch: "tbd/wt-create-codex",
        path: "/tmp/fake-repo-create-codex/wt-create-codex",
        tmuxServer: "tbd-c0de5678"
    )

    let request = try RPCRequest(
        method: RPCMethod.terminalCreate,
        params: TerminalCreateParams(worktreeID: wt.id, type: .codex)
    )
    let response = await router.handle(request)
    #expect(response.success, "expected success; error: \(response.error ?? "nil")")

    let terminal = try response.decodeResult(Terminal.self)
    #expect(terminal.kind == .codex)
    #expect(terminal.label == "Codex")

    let bodies = newWindowBodies(recorded.snapshot())
    #expect(bodies.contains { $0.contains("export CODEX_HOME=") },
            "created codex tab must export CODEX_HOME; got bodies: \(bodies)")
    #expect(bodies.contains {
        containsCodexProfileLaunch($0)
    }, "created codex tab must launch codex with the TBD profile; got bodies: \(bodies)")
    #expect(!bodies.contains { $0.contains("codex --full-auto") },
            "created codex tab must not use removed --full-auto flag; got bodies: \(bodies)")
}

@Test("handleTerminalCreate passes initial prompt to fresh Codex sessions")
func testHandleTerminalCreateCodexInitialPrompt() async throws {
    installCodexTestHomeOverride()
    defer { unsetenv("TBD_TEST_CODEX_HOME") }

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
        path: "/tmp/fake-repo-create-codex-prompt", displayName: "test", defaultBranch: "main"
    )
    let wt = try await db.worktrees.create(
        repoID: repo.id,
        name: "wt-create-codex-prompt",
        branch: "tbd/wt-create-codex-prompt",
        path: "/tmp/fake-repo-create-codex-prompt/wt-create-codex-prompt",
        tmuxServer: "tbd-c0de9876"
    )

    let request = try RPCRequest(
        method: RPCMethod.terminalCreate,
        params: TerminalCreateParams(
            worktreeID: wt.id,
            type: .codex,
            prompt: "don't ship regressions"
        )
    )
    let response = await router.handle(request)
    #expect(response.success, "expected success; error: \(response.error ?? "nil")")

    let bodies = newWindowBodies(recorded.snapshot())
    #expect(bodies.contains {
        containsCodexProfileLaunch($0) && $0.contains("'don'\\''t ship regressions'")
    }, "fresh codex tab must append the initial prompt as a shell-escaped positional argument; got bodies: \(bodies)")
}
