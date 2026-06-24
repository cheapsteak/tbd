import Testing
import Foundation
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("SuspendResumeCoordinator Tests")
struct SuspendResumeCoordinatorTests {

    /// Helper: create an in-memory DB with a repo, worktree, and suspended terminal.
    private func setupSuspendedTerminal() async throws -> (TBDDatabase, UUID, UUID) {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test-repo", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt",
            branch: "main", path: "/tmp/test-repo",
            tmuxServer: "tbd-test"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude-1", claudeSessionID: "session-abc"
        )
        try await db.terminals.setSuspended(
            id: terminal.id, sessionID: "session-abc", snapshot: "fake snapshot"
        )
        return (db, wt.id, terminal.id)
    }

    @Test func resumeSkippedWhenSuspendDisabled() async throws {
        let (db, worktreeID, terminalID) = try await setupSuspendedTerminal()
        let tmux = TmuxManager(dryRun: true)
        let coordinator = SuspendResumeCoordinator(db: db, tmux: tmux)

        // Verify terminal is suspended
        let before = try await db.terminals.get(id: terminalID)
        #expect(before?.suspendedAt != nil)
        #expect(before?.suspendedSnapshot != nil)

        // Simulate arriving at the worktree with suspend disabled
        await coordinator.selectionChanged(to: [worktreeID], suspendEnabled: false)

        // Brief wait — a hypothetical scheduleResume would fire after a 3s delay,
        // but since the gate should skip it, we just need enough time to assert nothing happened.
        try await Task.sleep(for: .milliseconds(1500))

        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.suspendedAt != nil, "Resume should NOT run when suspendEnabled is false")
    }

    @Test func resumeRunsWhenSuspendEnabled() async throws {
        let (db, worktreeID, terminalID) = try await setupSuspendedTerminal()
        let tmux = TmuxManager(dryRun: true)
        let coordinator = SuspendResumeCoordinator(db: db, tmux: tmux)

        await coordinator.selectionChanged(to: [worktreeID], suspendEnabled: true)

        let cleared = try await waitUntil {
            try await db.terminals.get(id: terminalID)?.suspendedAt == nil
        }
        #expect(cleared, "Resume should clear suspendedAt when suspendEnabled is true")
    }

    @Test func manualSuspendSkipsAlreadySuspended() async throws {
        let (db, _, terminalID) = try await setupSuspendedTerminal()
        let tmux = TmuxManager(dryRun: true)
        let coordinator = SuspendResumeCoordinator(db: db, tmux: tmux)

        let result = await coordinator.manualSuspend(terminalID: terminalID)
        #expect(result == .alreadySuspended)
    }

    @Test func manualSuspendRejectsNonClaudeTerminal() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test-repo", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt",
            branch: "main", path: "/tmp/test-repo",
            tmuxServer: "tbd-test"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "zsh"
        )
        let tmux = TmuxManager(dryRun: true)
        let coordinator = SuspendResumeCoordinator(db: db, tmux: tmux)

        let result = await coordinator.manualSuspend(terminalID: terminal.id)
        #expect(result == .notClaudeTerminal)
    }

    @Test func manualResumeSkipsNonSuspended() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test-repo", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt",
            branch: "main", path: "/tmp/test-repo",
            tmuxServer: "tbd-test"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude-1", claudeSessionID: "session-abc"
        )
        let tmux = TmuxManager(dryRun: true)
        let coordinator = SuspendResumeCoordinator(db: db, tmux: tmux)

        let result = await coordinator.manualResume(terminalID: terminal.id)
        #expect(result == .notSuspended)
    }

    @Test func autoResumeSkipsSuspendedCodexTerminalWithSessionMetadata() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test-repo-codex", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt-codex",
            branch: "main", path: "/tmp/test-repo-codex",
            tmuxServer: "tbd-codex"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@0",
            tmuxPaneID: "%0",
            label: "Codex",
            claudeSessionID: "session-abc",
            kind: .codex
        )
        try await db.terminals.setSuspended(
            id: terminal.id, sessionID: "session-abc", snapshot: "fake snapshot"
        )
        let tmux = TmuxManager(dryRun: true)
        let coordinator = SuspendResumeCoordinator(db: db, tmux: tmux)

        await coordinator.selectionChanged(to: [wt.id], suspendEnabled: true)
        try await Task.sleep(for: .milliseconds(250))

        let after = try await db.terminals.get(id: terminal.id)
        #expect(after?.suspendedAt != nil)
    }

    @Test func resumeInjectsTokenWhenResolverProvided() async throws {
        // Build DB with a token row + suspended terminal referencing it.
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test-repo", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt",
            branch: "main", path: "/tmp/test-repo",
            tmuxServer: "tbd-test"
        )
        // api-key profile — oauth profiles no longer inject a token.
        let token = try await db.modelProfiles.create(name: "test-token", kind: .apiKey)
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude-1", claudeSessionID: "session-abc",
            profileID: token.id
        )
        try await db.terminals.setSuspended(
            id: terminal.id, sessionID: "session-abc", snapshot: nil
        )

        // Stub keychain closure returns a known secret only for this token.
        let secret = "sk-ant-api03-FAKETOKEN_value"
        let resolver = ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config,
            keychain: { id in id == token.id.uuidString ? secret : nil }
        )

        // Recorder to capture the createWindow shellCommand argument.
        let recorded = RecordedCommands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { args in
            recorded.append(args)
        })
        let coordinator = SuspendResumeCoordinator(db: db, tmux: tmux, modelProfileResolver: resolver)

        await coordinator.selectionChanged(to: [wt.id], suspendEnabled: true)

        let cleared = try await waitUntil {
            try await db.terminals.get(id: terminal.id)?.suspendedAt == nil
        }
        #expect(cleared, "Resume should clear suspendedAt when suspendEnabled is true")

        // Find the createWindow invocation (it's the only dryRun call recorded here).
        let snap = recorded.snapshot()
        let resumeCall = snap.first { $0.joined(separator: " ").contains("claude --resume") }
        #expect(resumeCall != nil, "expected a createWindow call containing claude --resume")
        // Token must be passed via tmux -e flag, NOT inlined in the shell command argv.
        #expect(resumeCall?.contains("ANTHROPIC_API_KEY=\(secret)") == true,
                "expected token in tmux -e flag; got: \(resumeCall ?? [])")
        // The shell command body (last arg, after -ic) must NOT contain the secret.
        let shellBody = resumeCall?.last ?? ""
        #expect(!shellBody.contains(secret),
                "secret leaked into shell command body: \(shellBody)")
        #expect(!shellBody.contains("ANTHROPIC_API_KEY"),
                "env var name leaked into shell command body: \(shellBody)")
        #expect(shellBody.contains("claude --resume session-abc"))
    }

    @Test func resumeOmitsTokenWhenResolverNil() async throws {
        let (db, worktreeID, terminalID) = try await setupSuspendedTerminal()

        let recorded = RecordedCommands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { args in
            recorded.append(args)
        })
        // No resolver supplied — fallback branch.
        let coordinator = SuspendResumeCoordinator(db: db, tmux: tmux, modelProfileResolver: nil)

        await coordinator.selectionChanged(to: [worktreeID], suspendEnabled: true)

        let cleared = try await waitUntil {
            try await db.terminals.get(id: terminalID)?.suspendedAt == nil
        }
        #expect(cleared, "Resume should clear suspendedAt when suspendEnabled is true")

        let joined = recorded.snapshot().map { $0.joined(separator: " ") }
        let resumeArg = joined.first { $0.contains("claude --resume") }
        #expect(resumeArg != nil, "expected a createWindow call containing claude --resume")
        #expect(resumeArg?.contains("CLAUDE_CODE_OAUTH_TOKEN") == false,
                "fallback branch must not inject CLAUDE_CODE_OAUTH_TOKEN; got: \(resumeArg ?? "nil")")
        #expect(resumeArg?.contains("ANTHROPIC_API_KEY") == false)
        #expect(resumeArg?.contains("claude --resume session-abc") == true)
    }

    @Test func suspendSkippedWhenDisabled() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test-repo", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt",
            branch: "main", path: "/tmp/test-repo",
            tmuxServer: "tbd-test"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude-1", claudeSessionID: "session-abc"
        )
        let tmux = TmuxManager(dryRun: true)
        let coordinator = SuspendResumeCoordinator(db: db, tmux: tmux)

        // First: arrive at the worktree so it's in lastKnownSelection
        await coordinator.selectionChanged(to: [wt.id], suspendEnabled: false)
        // Seed the idle hook so the terminal would be eligible for suspend
        await coordinator.responseCompleted(worktreeID: wt.id)

        // Now depart with suspend disabled
        await coordinator.selectionChanged(to: [], suspendEnabled: false)

        // Wait for any async suspend to complete
        try await Task.sleep(for: .seconds(2))

        let after = try await db.terminals.get(id: terminal.id)
        #expect(after?.suspendedAt == nil, "Terminal should NOT be suspended when suspendEnabled is false")
    }

    /// Regression test for #285: on-demand Resume must bootstrap a dead tmux
    /// server before creating the resume window. After a reboot the tmux server
    /// is gone, so `createWindow` → `new-window` throws "no server running on …"
    /// unless `resumeTerminal` calls `ensureServer` first.
    ///
    /// This uses a REAL `TmuxManager` against a unique, NOT-running socket —
    /// the only way to actually exercise the dead-server bootstrap. The dryRun
    /// path can't model this: `serverExists` always returns true and
    /// `ensureServer` always returns nil in dryRun, so the bootstrap/kill code
    /// added by this fix never engages. Modeled on
    /// `testRecreateAfterRebootBootstrapKillOrdering` in WorktreeLifecycleTests.
    ///
    /// The resume window tmux creates runs `$SHELL -ic 'claude --resume <id> …'`.
    /// Its pane — and therefore the freshly-bootstrapped session and the whole
    /// server — stays alive only while that `claude` process keeps running. CI
    /// installs tmux but NOT the `claude` binary (see .github/workflows/test.yml),
    /// so on CI the resume shell hits "command not found", exits immediately, and
    /// the just-bootstrapped session collapses to zero windows — tearing down the
    /// server *before* `serverExists` is queried below. That made this test fail
    /// (flakily, racing tmux's async pane reaping) on CI while passing locally only
    /// because the developer happens to have a long-running `claude` installed.
    /// Remove that environmental dependency by shadowing `claude` with a stub that
    /// blocks (`exec /bin/sleep`), so the resume window is deterministically
    /// long-lived on any runner — the same trick the sibling real-tmux test uses
    /// when it spawns `sleep 60`. The stub is put on the tmux server's inherited
    /// PATH and the resume shell's rc is neutralized via ZDOTDIR; see the setup
    /// block below for why those are the only reliable levers.
    @Test func manualResumeBootstrapsDeadServer() async throws {
        let socketName = "tbd-test-\(UUID().uuidString.prefix(8))"
        let realTmux = TmuxManager()
        // Defensive: ensure no stray server is alive on this socket, and verify.
        try? await realTmux.killServer(server: socketName)
        let aliveBefore = await realTmux.serverExists(server: socketName)
        #expect(!aliveBefore, "Test precondition: socket \(socketName) must not have a live server")

        // Real repo dir on disk — tmux refuses to set cwd to a missing dir.
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "test", defaultBranch: "main"
        )
        // Worktree pointing at the dead socket — simulates post-reboot state.
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: repoDir.path, tmuxServer: socketName
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@stale-1", tmuxPaneID: "%stale-1",
            label: "claude-1", claudeSessionID: "session-abc"
        )
        try await db.terminals.setSuspended(
            id: terminal.id, sessionID: "session-abc", snapshot: "fake snapshot"
        )

        // Shadow `claude` with a blocking stub so the resume window's pane — and
        // thus the bootstrapped session and server — stays alive on any runner,
        // not just one that happens to have a long-running `claude` installed.
        // See the test's doc comment for the full rationale.
        //
        // Mechanism (the only one that proved reliable; tmux's `new-window -e
        // PATH=…` does NOT override the PATH a pane's shell ends up with):
        //  1. Prepend the stub dir to the *test process* PATH. `ensureServer`
        //     spawns the tmux server from this process, so the server — and every
        //     pane it later forks, including the resume window — inherits it.
        //  2. Point ZDOTDIR at an empty dir so the resume window's `$SHELL -ic`
        //     sources no user `.zshrc`. Without this, a developer rc that rebuilds
        //     PATH would drop the stub before `claude` is resolved (CI runners have
        //     no such rc, which is why the stub is reached there unaided). `-ic` is
        //     non-login, so /etc/zprofile's path_helper never runs.
        // Both are process-global, so restore them in `defer`. Unlike the
        // `setenv("TBD_HOME")` hazard CLAUDE.md calls out — where the flake was a
        // *logic* race (another suite read TBD_HOME and derived a wrong path) — no
        // test reads PATH or ZDOTDIR to make assertions, so that failure mode can't
        // occur here. The only concurrent consumers are subprocess spawns, for which
        // these values are additive/inert: prepending a `claude`-only dir changes no
        // other binary's resolution, and the sibling real-tmux suites spawn `sleep`,
        // which needs no rc. (Verified: these suites pass repeatedly under
        // `swift test --parallel` alongside this mutation.) Caveat for future work:
        // a new test that spawns an *interactive* shell expecting the user rc to
        // have run could observe the empty ZDOTDIR during this window — serialize
        // against this test if that ever becomes a concern.
        let stubBinDir = tempDir.appendingPathComponent("stub-bin")
        let emptyZDotDir = tempDir.appendingPathComponent("empty-zdotdir")
        try FileManager.default.createDirectory(at: stubBinDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyZDotDir, withIntermediateDirectories: true)
        let claudeStub = stubBinDir.appendingPathComponent("claude")
        // Absolute `/bin/sleep` so the stub does not itself depend on PATH.
        try "#!/bin/sh\nexec /bin/sleep 120\n".write(to: claudeStub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: claudeStub.path
        )
        let originalPath = ProcessInfo.processInfo.environment["PATH"]
        let originalZDotDir = ProcessInfo.processInfo.environment["ZDOTDIR"]
        setenv("PATH", "\(stubBinDir.path):\(originalPath ?? "/usr/bin:/bin")", 1)
        setenv("ZDOTDIR", emptyZDotDir.path, 1)
        defer {
            if let originalPath { setenv("PATH", originalPath, 1) } else { unsetenv("PATH") }
            if let originalZDotDir { setenv("ZDOTDIR", originalZDotDir, 1) } else { unsetenv("ZDOTDIR") }
        }

        let coordinator = SuspendResumeCoordinator(db: db, tmux: realTmux)

        let result = await coordinator.manualResume(terminalID: terminal.id)
        // Tear down inline on any failure (defer can't await).
        func teardown() async { try? await realTmux.killServer(server: socketName) }

        #expect(result == .ok)

        // The server must now be up — proof the bootstrap ran. Without the fix,
        // createWindow throws and the server stays dead.
        let aliveAfter = await realTmux.serverExists(server: socketName)
        if !aliveAfter {
            await teardown()
            Issue.record("tmux server must be running after resume bootstrapped a dead server")
            return
        }

        // The terminal's stale IDs must have been replaced with the freshly
        // created window/pane, and suspendedAt cleared.
        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.suspendedAt == nil, "resume must clear suspendedAt")
        #expect(updated?.tmuxWindowID != "@stale-1",
                "tmuxWindowID must be replaced with a freshly-allocated window ID")
        #expect(updated?.tmuxPaneID != "%stale-1",
                "tmuxPaneID must be replaced with a freshly-allocated pane ID")
        #expect(updated?.tmuxWindowID.hasPrefix("@") == true)
        #expect(updated?.tmuxPaneID.hasPrefix("%") == true)

        // The bootstrap placeholder must have been killed — the session should
        // hold exactly the one window we created for the resume.
        let windows = try await realTmux.listWindows(server: socketName, session: "main")
        #expect(windows.count == 1,
                "session should contain exactly the freshly-created resume window; got \(windows)")

        await teardown()
    }

    /// Polls `condition` every 50ms until it returns true, up to `timeout`.
    /// Use this when awaiting fire-and-forget actor work that has no
    /// synchronization point — `Task.sleep(.seconds(N))` is brittle under
    /// `swift test --parallel` load where scheduling delays can stretch
    /// nominally sub-second work to many seconds.
    private func waitUntil(
        timeout: Duration = .seconds(30),
        pollInterval: Duration = .milliseconds(50),
        _ condition: () async throws -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: pollInterval)
        }
        return try await condition()
    }
}

/// Thread-safe collector for TmuxManager dryRun recorded args.
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
