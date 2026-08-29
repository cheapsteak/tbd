import Foundation
import Testing
import TestSupport
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

private final class ServerLockGate: @unchecked Sendable {
    private let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let release: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation

    init() {
        (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        (release, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    func hold(_ tmux: TmuxManager, server: String) -> Task<Void, Never> {
        Task {
            await tmux.withServerResourceLock(server: server) { [self] in
                enteredContinuation.yield()
                var iterator = release.makeAsyncIterator()
                _ = await iterator.next()
            }
        }
    }

    func waitUntilHeld() async {
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
    }

    func unlock() {
        releaseContinuation.yield()
    }
}

private final class BlockingProfileInterruptProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseGate = DispatchSemaphore(value: 0)
    private var blocked = false

    var isBlocked: Bool { lock.withLock { blocked } }

    func record(_ args: [String]) {
        guard args.contains("send-keys") else { return }
        let shouldBlock = lock.withLock { () -> Bool in
            guard !blocked else { return false }
            blocked = true
            return true
        }
        if shouldBlock {
            releaseGate.waitForGate("profile replacement interrupt")
        }
    }

    func release() {
        releaseGate.signal()
    }
}

/// Returns the shell command body (last argument of `new-window`) for any
/// recorded `new-window` invocation. tmux argv ends with
/// `<shell> -i -l -c <body>` (separate flag elements, see
/// TmuxManager.shellFlags(forShell:)) when env vars are inlined, so the body
/// is the last element.
private func newWindowBodies(_ recorded: [[String]]) -> [String] {
    recorded.compactMap { call in
        guard call.contains("new-window") else { return nil }
        return call.last
    }
}

private let codexDryRunExecutable = "/opt/tbd-test/bin/codex"

private func containsCodexProfileLaunch(_ body: String) -> Bool {
    let executable = SystemPromptBuilder.shellEscape(codexDryRunExecutable)
    return body.contains(
        "unset CODEX_CI CODEX_THREAD_ID; \(executable) --profile tbd --dangerously-bypass-approvals-and-sandbox")
        || body.contains(
            "unset CODEX_CI CODEX_THREAD_ID; \(executable) --profile-v2 tbd --dangerously-bypass-approvals-and-sandbox")
}

/// Points `TBD_TEST_CODEX_HOME` at a fresh temp dir for one test, and returns
/// the teardown that puts the previous value back.
///
/// Previously a file-scope `let` did a one-time `setenv` for the whole process
/// and each test's `defer` called `unsetenv`. Both halves were wrong now that
/// `scripts/test.sh` exports this variable for the entire run: the `unsetenv`
/// punched a hole straight through the fence, handing every concurrently
/// running suite the developer's real `~/.codex`. Restore, never unset — see
/// `setCodexTestHome(_:)`.
private func isolateCodexHome() -> (home: URL, cleanup: () -> Void) {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-codex-home-tests-\(UUID().uuidString)", isDirectory: true)
    let prior = setCodexTestHome(home.path)
    return (home, {
        restoreCodexTestHome(prior)
        try? FileManager.default.removeItem(at: home)
    })
}

/// terminal.create / terminal.recreateWindow refuse to spawn into a missing
/// directory (tmux would silently fall back to $HOME), so fixtures must
/// materialize their fake worktree paths on disk. Idempotent.
private func ensureWorktreeDir(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
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
        tmux: tmux,
        actuationLog: makeTestActuationLog()
    )

    let repo = try await db.repos.create(
        path: "/tmp/fake-repo-recreate", displayName: "test", defaultBranch: "main"
    )
    try ensureWorktreeDir("/tmp/fake-repo-recreate/wt-recreate")
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

    // TBD_TERMINAL_ID too, and for a second reason: it is what `createWindow`
    // stamps onto the new pane as `@tbd_terminal_id`. Without it this branch
    // mints panes that `terminal.send` can never verify, because a pane with no
    // identity is sent to unchecked — a permanent hole in the stale-coordinate
    // refusal for every terminal recreated this way.
    let expectedTerminal = "export TBD_TERMINAL_ID='\(terminal.id.uuidString)';"
    #expect(bodies.contains { $0.contains(expectedTerminal) },
            "handleTerminalRecreateWindow must export TBD_TERMINAL_ID; got bodies: \(bodies)")
    #expect(recorded.snapshot().contains { call in
        call.contains("set-option") && call.contains(TmuxManager.terminalIDPaneOption)
            && call.contains(terminal.id.uuidString)
    }, "the recreated pane must be stamped with its terminal id")

    let updated = try response.decodeResult(Terminal.self)
    let incarnationID = try #require(updated.sessionIncarnationID)
    let matchedCLIPath = try #require(AgentProcessEnvironment.cliPath)
    let replacementCommand = try #require(recorded.snapshot().last { call in
        call.contains("respawn-window")
    }?.last)
    #expect(replacementCommand.contains(
        "TBD_TERMINAL_INCARNATION_ID='\(incarnationID.uuidString)'"))
    #expect(replacementCommand.contains(
        "TBD_CLI_PATH=\(SystemPromptBuilder.shellEscape(matchedCLIPath))"))
    #expect(bodies.contains { $0.contains("tail -f /dev/null") },
            "the replacement window must stay inert until its token commits")

    let manualAgentHook = try RPCRequest(
        method: RPCMethod.terminalSessionEvent,
        params: TerminalSessionEventParams(
            terminalID: terminal.id,
            sessionID: "manual-agent-session",
            transcriptPath: "/tmp/manual-agent-session.jsonl",
            source: "startup",
            sessionIncarnationID: incarnationID))
    #expect((await router.handle(manualAgentHook)).success)
    #expect(try await db.terminals.get(id: terminal.id)?.claudeSessionID
            == "manual-agent-session")
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
    // The window is genuinely DEAD (the premise of this scenario); the stale-
    // caller gate must not trip. dryRun default would report it alive.
    let tmux = TmuxManager(dryRun: true, dryRunWindowIsDead: { _ in true })
    let router = RPCRouter(
        db: db,
        lifecycle: WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: tmux,
            hooks: HookResolver()
        ),
        tmux: tmux,
        actuationLog: makeTestActuationLog()
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
    #expect(updated.isParked, "claude terminal must be parked (resumable), not recreated as shell")
    #expect(updated.kind == .claude, "kind must stay .claude, not flip to .shell")
    #expect(updated.claudeSessionID == sessionID, "claudeSessionID must be preserved")
    #expect(updated.transcriptPath == transcriptPath, "transcriptPath must be preserved")
    #expect(updated.isClaudeResumable, "parked terminal must remain Claude-resumable")
}

// MARK: - The re-park branch is an actuation, and carries its own row

/// A readable actuation-log path for the two tests below, plus the rows in it.
/// `makeTestActuationLog()` is deliberately opaque about its path; these tests
/// assert on the record, so they build their own under `$TMPDIR`.
private func makeReadableActuationLog() throws -> (log: ActuationLog, path: String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-actuation-repark-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("actuations.jsonl").path
    return (ActuationLog(path: path), path)
}

/// A path that can never be opened: its parent is a regular file.
private func makeUnwritableActuationLogPath() throws -> String {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-actuation-blocked-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let blocker = directory.appendingPathComponent("blocker")
    try Data("not a directory".utf8).write(to: blocker)
    return blocker.appendingPathComponent("actuations.jsonl").path
}

private func actuationRows(at path: String) throws -> [[String: Any]] {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return try contents
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
}

/// The re-park branch kills a window it read as dead and parks the session. It
/// is an actuation, not a DB-only edit — the `windowExists` read one line
/// earlier can be stale — so it writes its own `hibernate` row through
/// `terminal.recreateWindow`'s door, the same act reconcile's recovery park
/// records.
@Test("the recreateWindow re-park writes one hibernate request and one dispatched outcome")
func testRecreateWindowReparkWritesHibernateRow() async throws {
    let db = try TBDDatabase(inMemory: true)
    // The window is genuinely DEAD: the premise of the re-park branch.
    let tmux = TmuxManager(dryRun: true, dryRunWindowIsDead: { _ in true })
    let (log, logPath) = try makeReadableActuationLog()
    let router = RPCRouter(
        db: db,
        lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
        tmux: tmux,
        actuationLog: log
    )

    let repo = try await db.repos.create(
        path: "/tmp/fake-repo-repark-row", displayName: "test", defaultBranch: "main")
    let wt = try await db.worktrees.create(
        repoID: repo.id,
        name: "wt-repark-row",
        branch: "tbd/wt-repark-row",
        path: "/tmp/fake-repo-repark-row/wt-repark-row",
        tmuxServer: "tbd-4e9a4c01"
    )
    let sessionID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let terminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "@dead-claude",
        tmuxPaneID: "%dead-claude",
        label: "claude",
        claudeSessionID: sessionID,
        kind: .claude
    )

    let response = await router.handle(try RPCRequest(
        method: RPCMethod.terminalRecreateWindow,
        params: TerminalRecreateWindowParams(terminalID: terminal.id),
        actor: ActuationActor.app))
    #expect(response.success, "expected success; error: \(response.error ?? "nil")")

    let written = try actuationRows(at: logPath)
    #expect(written.count == 2, "exactly one request and one outcome; got \(written)")
    let request = try #require(written.first)
    // A park, recorded as one — not as the surface's usual spawn.
    #expect(request["kind"] as? String == "hibernate")
    #expect(request["method"] as? String == "terminal.recreateWindow")
    let target = try #require(request["target"] as? [String: Any])
    #expect(target["worktree"] as? String == wt.id.uuidString)
    #expect(target["terminal"] as? String == terminal.id.uuidString)
    let actor = try #require(request["actor"] as? [String: Any])
    #expect(actor["kind"] as? String == "app")

    let outcome = try #require(written.last)
    #expect(outcome["kind"] as? String == "outcome")
    #expect(outcome["confirms"] as? String == request["id"] as? String)
    #expect(outcome["result"] as? String == "dispatched")

    let updated = try #require(try await db.terminals.get(id: terminal.id))
    #expect(updated.isParked, "the park itself must still happen")
}

/// Fail-closed: an unwritable record refuses the re-park before the kill. The
/// window is not killed and the row is not parked, and the caller gets the
/// self-explaining log error rather than a silent, unrecorded teardown.
@Test("an unwritable record refuses the recreateWindow re-park before the kill")
func testRecreateWindowReparkRefusedWhenRecordUnwritable() async throws {
    let db = try TBDDatabase(inMemory: true)
    let recorded = RecordedCommands()
    let tmux = TmuxManager(
        dryRun: true, dryRunRecorder: { recorded.append($0) }, dryRunWindowIsDead: { _ in true })
    let router = RPCRouter(
        db: db,
        lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
        tmux: tmux,
        actuationLog: ActuationLog(path: try makeUnwritableActuationLogPath())
    )

    let repo = try await db.repos.create(
        path: "/tmp/fake-repo-repark-refused", displayName: "test", defaultBranch: "main")
    let wt = try await db.worktrees.create(
        repoID: repo.id,
        name: "wt-repark-refused",
        branch: "tbd/wt-repark-refused",
        path: "/tmp/fake-repo-repark-refused/wt-repark-refused",
        tmuxServer: "tbd-4e9a4c02"
    )
    let sessionID = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
    let terminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "@dead-claude-refused",
        tmuxPaneID: "%dead-claude-refused",
        label: "claude",
        claudeSessionID: sessionID,
        kind: .claude
    )

    let response = await router.handle(try RPCRequest(
        method: RPCMethod.terminalRecreateWindow,
        params: TerminalRecreateWindowParams(terminalID: terminal.id)))
    #expect(!response.success, "an unrecordable park must not be performed")
    #expect(response.error?.contains("actuation log") == true,
            "the caller must see the self-explaining log error; got: \(response.error ?? "nil")")

    let joined = recorded.snapshot().map { $0.joined(separator: " ") }
    #expect(!joined.contains { $0.contains("kill-window") },
            "the kill must not run ahead of an unwritable record; got: \(joined)")

    let updated = try #require(try await db.terminals.get(id: terminal.id))
    #expect(!updated.isParked, "the refused act must leave the row unparked")
}

/// Stale-caller gate: when the claude terminal's CURRENT window is actually
/// ALIVE (the app's dead-window path raced a wake that just recreated the
/// window and updated the row's ids), `handleTerminalRecreateWindow` must NOT
/// kill the window or re-park the row — that tears down the freshly-spawned
/// claude and flaps the wake. It returns the row unchanged.
@Test("handleTerminalRecreateWindow ignores a stale request when the claude window is alive")
func testHandleTerminalRecreateWindowIgnoresStaleRequestWhenWindowAlive() async throws {
    let db = try TBDDatabase(inMemory: true)
    let recorded = RecordedCommands()
    let (actuationLog, actuationLogPath) = try makeReadableActuationLog()
    // dryRun default: every window reports ALIVE.
    let tmux = TmuxManager(dryRun: true, dryRunRecorder: { recorded.append($0) })
    let router = RPCRouter(
        db: db,
        lifecycle: WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: tmux,
            hooks: HookResolver()
        ),
        tmux: tmux,
        actuationLog: actuationLog
    )

    let repo = try await db.repos.create(
        path: "/tmp/fake-repo-recreate-stale", displayName: "test", defaultBranch: "main"
    )
    let wt = try await db.worktrees.create(
        repoID: repo.id,
        name: "wt-recreate-stale",
        branch: "tbd/wt-recreate-stale",
        path: "/tmp/fake-repo-recreate-stale/wt-recreate-stale",
        tmuxServer: "tbd-51a1e000"
    )
    let sessionID = "66666666-7777-8888-9999-aaaaaaaaaaaa"
    let terminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "@live-claude",
        tmuxPaneID: "%live-claude",
        label: "claude",
        claudeSessionID: sessionID,
        kind: .claude
    )

    let request = try RPCRequest(
        method: RPCMethod.terminalRecreateWindow,
        params: TerminalRecreateWindowParams(terminalID: terminal.id)
    )
    let response = await router.handle(request)
    #expect(response.success, "expected success; error: \(response.error ?? "nil")")

    let updated = try #require(try await db.terminals.get(id: terminal.id))
    #expect(!updated.isParked, "a live-window claude row must NOT be re-parked by a stale request")
    #expect(updated.tmuxWindowID == "@live-claude", "tmux ids must be untouched")
    #expect(updated.tmuxPaneID == "%live-claude")

    let joined = recorded.snapshot().map { $0.joined(separator: " ") }
    #expect(!joined.contains { $0.contains("kill-window") },
            "the alive window must NOT be killed; got: \(joined)")

    let returned = try response.decodeResult(Terminal.self)
    #expect(returned.id == terminal.id)
    #expect(!returned.isParked, "the returned row must be the current, un-parked one")

    let written = try actuationRows(at: actuationLogPath)
    #expect(written.count == 2, "the declined re-park must close its request; got \(written)")
    let requestRow = try #require(written.first)
    let outcome = try #require(written.last)
    #expect(requestRow["kind"] as? String == "hibernate")
    #expect(outcome["kind"] as? String == "outcome")
    #expect(outcome["confirms"] as? String == requestRow["id"] as? String)
    #expect(outcome["result"] as? String == "refused")
    #expect(outcome["reason"] as? String == "not-eligible")
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
        tmux: tmux,
        actuationLog: makeTestActuationLog()
    )

    let repo = try await db.repos.create(
        path: "/tmp/fake-repo-recreate-shell", displayName: "test", defaultBranch: "main"
    )
    try ensureWorktreeDir("/tmp/fake-repo-recreate-shell/wt-recreate-shell")
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

@Test("a queued shell recreation cannot overwrite a newer replacement")
func queuedShellRecreationRejectsNewerReplacement() async throws {
    let db = try TBDDatabase(inMemory: true)
    let recorded = RecordedCommands()
    let tmux = TmuxManager(dryRun: true, dryRunRecorder: recorded.append)
    let (log, logPath) = try makeReadableActuationLog()
    let router = RPCRouter(
        db: db,
        lifecycle: WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
        tmux: tmux,
        actuationLog: log)
    let repoPath = "/tmp/fake-repo-recreate-shell-race"
    let worktreePath = "\(repoPath)/wt"
    try ensureWorktreeDir(worktreePath)
    let repo = try await db.repos.create(
        path: repoPath, displayName: "test", defaultBranch: "main")
    let worktree = try await db.worktrees.create(
        repoID: repo.id, name: "wt", branch: "main", path: worktreePath,
        tmuxServer: "tbd-shell-recreate-race")
    let terminal = try await db.terminals.create(
        worktreeID: worktree.id,
        tmuxWindowID: "@old", tmuxPaneID: "%old",
        label: TerminalLabel.shell, kind: .shell)

    let lockGate = ServerLockGate()
    let holder = lockGate.hold(tmux, server: worktree.tmuxServer)
    await lockGate.waitUntilHeld()
    defer { lockGate.unlock() }
    let request = try RPCRequest(
        method: RPCMethod.terminalRecreateWindow,
        params: TerminalRecreateWindowParams(terminalID: terminal.id))
    let recreation = gateHoldingTask { await router.handle(request) }
    guard await waitUntil({
        (try? actuationRows(at: logPath).contains {
            $0["method"] as? String == RPCMethod.terminalRecreateWindow
        }) == true
    }) else {
        lockGate.unlock()
        _ = await holder.value
        _ = await recreation.value
        Issue.record("recreation never reached the held server lock")
        return
    }

    _ = try await db.terminals.replaceRecreatedShellWindow(
        id: terminal.id,
        expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
        windowID: "@replacement", paneID: "%replacement",
        at: Date(timeIntervalSinceReferenceDate: 10))
    let replacement = try #require(try await db.terminals.get(id: terminal.id))
    let commandCount = recorded.snapshot().count
    lockGate.unlock()
    _ = await holder.value

    #expect(!(await recreation.value).success)
    let unchanged = try #require(try await db.terminals.get(id: terminal.id))
    #expect(unchanged == replacement)
    #expect(recorded.snapshot().count == commandCount,
            "a stale recreation must issue no kill, create, or respawn")
}

@Test("a delayed Claude re-park cannot kill a completed profile replacement")
func delayedClaudeReparkRejectsProfileReplacement() async throws {
    let db = try TBDDatabase(inMemory: true)
    let recorded = RecordedCommands()
    let profileInterrupt = BlockingProfileInterruptProbe()
    let tmux = TmuxManager(
        dryRun: true,
        dryRunRecorder: { args in
            recorded.append(args)
            profileInterrupt.record(args)
        })
    let configDirs = ClaudeProfileConfigDirManager(
        baseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-repark-profiles-\(UUID().uuidString)"),
        hostBaseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-repark-host-\(UUID().uuidString)"))
    let (actuationLog, actuationLogPath) = try makeReadableActuationLog()
    let router = RPCRouter(
        db: db,
        lifecycle: WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
            configDirManager: configDirs),
        tmux: tmux,
        configDirManager: configDirs,
        actuationLog: actuationLog)
    let repoPath = "/tmp/fake-repo-repark-profile-race"
    let worktreePath = "\(repoPath)/wt"
    try ensureWorktreeDir(worktreePath)
    let repo = try await db.repos.create(
        path: repoPath, displayName: "test", defaultBranch: "main")
    let worktree = try await db.worktrees.create(
        repoID: repo.id, name: "wt", branch: "main", path: worktreePath,
        tmuxServer: "tbd-repark-profile-race")
    let terminal = try await db.terminals.create(
        worktreeID: worktree.id,
        tmuxWindowID: "@claude", tmuxPaneID: "%claude",
        label: TerminalLabel.claudeCode,
        claudeSessionID: "source-session", kind: .claude)
    let profile = try await db.modelProfiles.create(name: "Replacement", kind: .oauth)

    let profileRequest = try RPCRequest(
        method: RPCMethod.terminalSwapProfile,
        params: TerminalSwapProfileParams(
            terminalID: terminal.id, newProfileID: profile.id, mode: .inPlace))
    let profileTask = gateHoldingTask { await router.handle(profileRequest) }
    guard await waitUntil({ profileInterrupt.isBlocked }) else {
        profileInterrupt.release()
        _ = await profileTask.value
        Issue.record("profile replacement never reached the respawn")
        return
    }

    let recreateRequest = try RPCRequest(
        method: RPCMethod.terminalRecreateWindow,
        params: TerminalRecreateWindowParams(terminalID: terminal.id))
    let repark = gateHoldingTask { await router.handle(recreateRequest) }
    guard await waitUntil({
        (try? actuationRows(at: actuationLogPath).contains {
            $0["method"] as? String == RPCMethod.terminalRecreateWindow
        }) == true
    }) else {
        profileInterrupt.release()
        _ = await profileTask.value
        _ = await repark.value
        Issue.record("re-park never reached the held server lock")
        return
    }
    profileInterrupt.release()

    let profileResponse = await profileTask.value
    #expect(profileResponse.success)
    let replacement = try #require(try await db.terminals.get(id: terminal.id))

    #expect(!(await repark.value).success)
    let unchanged = try #require(try await db.terminals.get(id: terminal.id))
    #expect(unchanged == replacement)
    #expect(!unchanged.isParked)
    let commands = recorded.snapshot().map { $0.joined(separator: " ") }
    #expect(!commands.contains { $0.contains("kill-window") },
            "the stale re-park must not kill the replacement pane; got: \(commands)")
    #expect(!commands.contains { $0.contains("new-window") },
            "the stale re-park must not recreate a window; got: \(commands)")
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
        tmux: tmux,
        actuationLog: makeTestActuationLog()
    )

    let repo = try await db.repos.create(
        path: "/tmp/fake-repo-create", displayName: "test", defaultBranch: "main"
    )
    try ensureWorktreeDir("/tmp/fake-repo-create/wt-create")
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

// MARK: - Codex launch command

// Nested under TBDHomeSerialized: these tests mutate the process-global
// `TBD_TEST_CODEX_HOME` to keep `CodexHomeManager` out of the real `~/.codex`.
// There is no injection seam for it — `RPCRouter` and `WorktreeLifecycle`
// construct `CodexHomeManager()` internally — so the env var is the only
// override, and nesting is what stops it racing the other env-mutating suites.
// See TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {
@Suite("Codex launch command (worktree-id leak fixtures)")
struct CodexLaunchCommandTests {

    @Test("handleTerminalRecreateWindow uses current Codex launch command")
    func testHandleTerminalRecreateWindowCodexLaunchCommand() async throws {
        let codex = isolateCodexHome(); defer { codex.cleanup() }

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
            tmux: tmux,
            actuationLog: makeTestActuationLog()
        )

        let repo = try await db.repos.create(
            path: "/tmp/fake-repo-recreate-codex", displayName: "test", defaultBranch: "main"
        )
        try ensureWorktreeDir("/tmp/fake-repo-recreate-codex/wt-recreate-codex")
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

        let commands = recorded.snapshot()
        let stagedBodies = newWindowBodies(commands)
        let respawnBodies = commands.compactMap { command -> String? in
            guard command.contains("respawn-window") else { return nil }
            return command.last
        }
        #expect(!stagedBodies.contains {
            containsCodexProfileLaunch($0)
        }, "recreated codex tab must not launch codex before its durable reset; got bodies: \(stagedBodies)")
        #expect(respawnBodies.contains {
            containsCodexProfileLaunch($0)
        }, "recreated codex tab must respawn codex with the TBD profile; got bodies: \(respawnBodies)")
        #expect(!respawnBodies.contains { $0.contains("codex --full-auto") },
                "recreated codex tab must not use removed --full-auto flag; got bodies: \(respawnBodies)")
    }

    @Test("a queued Codex recreation cannot overwrite a newer replacement")
    func queuedCodexRecreationRejectsNewerReplacement() async throws {
        let codex = isolateCodexHome(); defer { codex.cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedCommands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: recorded.append)
        let (log, logPath) = try makeReadableActuationLog()
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            actuationLog: log)
        let repoPath = "/tmp/fake-repo-recreate-codex-race"
        let worktreePath = "\(repoPath)/wt"
        try ensureWorktreeDir(worktreePath)
        let repo = try await db.repos.create(
            path: repoPath, displayName: "test", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main", path: worktreePath,
            tmuxServer: "tbd-codex-recreate-race")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: "@old", tmuxPaneID: "%old",
            label: TerminalLabel.codex, kind: .codex)

        let lockGate = ServerLockGate()
        let holder = lockGate.hold(tmux, server: worktree.tmuxServer)
        await lockGate.waitUntilHeld()
        defer { lockGate.unlock() }
        let request = try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminal.id))
        let recreation = gateHoldingTask { await router.handle(request) }
        guard await waitUntil({
            (try? actuationRows(at: logPath).contains {
                $0["method"] as? String == RPCMethod.terminalRecreateWindow
            }) == true
        }) else {
            lockGate.unlock()
            _ = await holder.value
            _ = await recreation.value
            Issue.record("Codex recreation never reached the held server lock")
            return
        }

        _ = try await db.terminals.replaceRecreatedCodexWindow(
            id: terminal.id,
            expectedIncarnation: TerminalSessionIncarnation(terminal: terminal),
            windowID: "@replacement", paneID: "%replacement",
            at: Date(timeIntervalSinceReferenceDate: 10))
        let replacement = try #require(try await db.terminals.get(id: terminal.id))
        let commandCount = recorded.snapshot().count
        lockGate.unlock()
        _ = await holder.value

        #expect(!(await recreation.value).success)
        let unchanged = try #require(try await db.terminals.get(id: terminal.id))
        #expect(unchanged == replacement)
        #expect(recorded.snapshot().count == commandCount,
                "a stale recreation must issue no kill, create, or respawn")
    }

    @Test("handleTerminalCreate uses current Codex launch command")
    func testHandleTerminalCreateCodexLaunchCommand() async throws {
        let codex = isolateCodexHome(); defer { codex.cleanup() }

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
            tmux: tmux,
            actuationLog: makeTestActuationLog()
        )

        let repo = try await db.repos.create(
            path: "/tmp/fake-repo-create-codex", displayName: "test", defaultBranch: "main"
        )
        try ensureWorktreeDir("/tmp/fake-repo-create-codex/wt-create-codex")
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
        // The codex window must carry `-e DISABLE_AUTO_UPDATE=true` (process env,
        // set before .zshrc runs) so oh-my-zsh's interactive update prompt can't
        // block the spawned codex command.
        // Adjacency-checked like PreSessionHookTests.hasProcessEnvFlag (that
        // helper is file-private): a bare substring match could false-positive
        // on the shell command body.
        let codexCall = try #require(recorded.snapshot().first { $0.contains("new-window") })
        let hasFlag = codexCall.firstIndex(of: "DISABLE_AUTO_UPDATE=true")
            .map { $0 > codexCall.startIndex && codexCall[codexCall.index(before: $0)] == "-e" } ?? false
        #expect(hasFlag,
                "codex window must suppress the oh-my-zsh update prompt via -e; got: \(codexCall)")
    }

    @Test("handleTerminalCreate passes initial prompt to fresh Codex sessions")
    func testHandleTerminalCreateCodexInitialPrompt() async throws {
        let codex = isolateCodexHome(); defer { codex.cleanup() }

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
            tmux: tmux,
            actuationLog: makeTestActuationLog()
        )

        let repo = try await db.repos.create(
            path: "/tmp/fake-repo-create-codex-prompt", displayName: "test", defaultBranch: "main"
        )
        try ensureWorktreeDir("/tmp/fake-repo-create-codex-prompt/wt-create-codex-prompt")
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
}
}
