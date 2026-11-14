import Foundation
import Testing
import DaemonTestSupport
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel

/// Regression tests for the bug where spawned sessions inherited a stale
/// `TBD_WORKTREE_ID` from the environment they were started in, mis-routing
/// notifications from sub-worktrees to the main worktree.
///
/// Two surfaces are covered:
///  1. `Daemon.scrubInheritedTBDEnv()` clears poisoning vars from the daemon's
///     own env before any session is spawned.
///  2. The spawn paths (`createWorktree`'s setup tab and `terminal.create`)
///     export `TBD_WORKTREE_ID` into every session they open, read here from
///     the launch the holder spawn double recorded.

private let codexDryRunExecutable = "/opt/tbd-test/bin/codex"

private func containsCodexProfileLaunch(_ body: String) -> Bool {
    let executable = shellEscape(codexDryRunExecutable)
    return body.contains(
        "unset CODEX_CI CODEX_THREAD_ID; \(executable) --profile tbd --no-daemon --dangerously-bypass-approvals-and-sandbox")
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

/// terminal.create refuses to spawn into a missing directory, so fixtures
/// must materialize their fake worktree paths on disk. Idempotent.
private func ensureWorktreeDir(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

/// A router whose spawns go through the holder spawn double, wired into both
/// the router and the lifecycle it copies, as the daemon wires its registry.
private func makeHolderBackedRouter(
    db: TBDDatabase
) -> (router: RPCRouter, holder: FakeHolderLaunch) {
    let holder = FakeHolderLaunch()
    let registry = makeHolderRegistryDouble(launch: holder)
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )
    lifecycle.holderRegistry = registry
    let router = RPCRouter(
        db: db,
        lifecycle: lifecycle,
        tmux: TmuxManager(dryRun: true),
        actuationLog: makeTestActuationLog()
    )
    router.holderRegistry = registry
    return (router, holder)
}

// MARK: - Fix 1: Daemon scrubInheritedTBDEnv

@Test("Daemon.scrubInheritedTBDEnv clears every enclosing-session marker")
func testScrubInheritedTBDEnv() {
    // The whole marker set, minus the two names this in-process test must not
    // touch — the startup scrub's scope is the set, so pinning a hand-written
    // subset here would let a name added to `SpawnBaseEnvironment` go
    // unexercised on the daemon's own environment.
    //
    // `TMUX` and `TMUX_PANE` are excluded because `setenv` mutates the whole
    // test BINARY's environment while every other suite runs concurrently in
    // it, and a tmux client that finds `TMUX` set concludes it is already
    // inside a session and refuses to nest. A transient `TMUX` here would make
    // any tmux client a concurrently running live suite spawns fail. Their
    // membership in the set is covered without a process-wide mutation by
    // `SpawnBaseEnvironmentTests`, over an injected dictionary.
    //
    // `CLAUDE_CONFIG_DIR` is absent for a different reason: it is not a marker,
    // it is the one name the scrub judges by VALUE, and setting it in-process
    // would hand every concurrent suite that resolves the ambient Claude config
    // dir a sentinel path. That by-value rule is covered over injected
    // dictionaries by `SpawnBaseEnvironmentTests` and
    // `TmuxServerEnvironmentRepairTests`.
    let names = SpawnBaseEnvironment.enclosingSessionMarkers
        .subtracting(SpawnBaseEnvironment.tmuxPaneMarkers)
        .sorted()

    // setenv/unsetenv mutate the shared process environ. Guarantee cleanup
    // even if #expect failures or future edits cause us to skip the scrub
    // call below — Swift Testing runs tests concurrently by default and any
    // future test that reads these vars must not see leaked sentinels.
    defer {
        for name in names { unsetenv(name) }
    }

    for name in names { setenv(name, "leaked-\(name)", 1) }

    // Sanity: setenv worked.
    #expect(ProcessInfo.processInfo.environment["TBD_WORKTREE_ID"] == "leaked-TBD_WORKTREE_ID")

    Daemon.scrubInheritedTBDEnv()

    for name in names {
        #expect(
            ProcessInfo.processInfo.environment[name] == nil,
            "\(name) survived the startup scrub")
    }
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
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // The setup tab opens only when a setup hook resolves, so install one as
    // the global default hook, through the resolver's own seam.
    let hooksDir = tempDir.appendingPathComponent("global-hooks", isDirectory: true)
    try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
    let setupHook = hooksDir.appendingPathComponent(HookEvent.setup.rawValue)
    try "#!/bin/sh\nexit 0\n".write(to: setupHook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: setupHook.path)

    let db = try TBDDatabase(inMemory: true)
    let holder = FakeHolderLaunch()
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(globalHooksDir: hooksDir.path)
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: holder)

    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )
    let override = tempDir.appendingPathComponent(".tbd/worktrees").path
    try await db.repos.updateWorktreeRoot(id: repo.id, path: override)
    let resolvedRepo = try await db.repos.get(id: repo.id)!

    // skipClaude: true puts a plain shell in the primary tab, and the second
    // tab is the setup tab — the very thing we're testing here.
    let wt = try await lifecycle.createWorktree(repoID: resolvedRepo.id, skipClaude: true)

    // Two terminals expected: shell + setup
    let terminals = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminals.count == 2, "expected 2 terminals (shell + setup)")
    guard let setup = terminals.first(where: { $0.label == "setup" }) else {
        Issue.record("setup terminal not found; got: \(terminals.map { $0.label ?? "nil" })")
        return
    }

    let commandLine = holder.launch(for: setup.id)?.commandLine ?? ""
    let expectedWorktree = "export TBD_WORKTREE_ID='\(wt.id.uuidString)';"
    let expectedTerminal = "export TBD_TERMINAL_ID='\(setup.id.uuidString)';"
    #expect(
        commandLine.contains(expectedWorktree) && commandLine.contains(expectedTerminal),
        "setup tab must export both TBD_WORKTREE_ID and TBD_TERMINAL_ID matching its DB row; got: \(commandLine)"
    )
}

// MARK: - Regression: handleTerminalCreate still sets TBD_WORKTREE_ID

@Test("handleTerminalCreate (regression) still exports the correct TBD_WORKTREE_ID")
func testHandleTerminalCreateRegressionWorktreeID() async throws {
    let db = try TBDDatabase(inMemory: true)
    let (router, holder) = makeHolderBackedRouter(db: db)

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

    let terminal = try response.decodeResult(Terminal.self)
    let commandLine = holder.launch(for: terminal.id)?.commandLine ?? ""
    let expected = "export TBD_WORKTREE_ID='\(wt.id.uuidString)';"
    #expect(commandLine.contains(expected),
            "handleTerminalCreate must export TBD_WORKTREE_ID matching params.worktreeID; got: \(commandLine)")
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

    @Test("handleTerminalCreate uses current Codex launch command")
    func testHandleTerminalCreateCodexLaunchCommand() async throws {
        let codex = isolateCodexHome(); defer { codex.cleanup() }

        let db = try TBDDatabase(inMemory: true)
        let (router, holder) = makeHolderBackedRouter(db: db)

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

        let launch = try #require(holder.launch(for: terminal.id))
        let commandLine = launch.commandLine ?? ""
        #expect(commandLine.contains("export CODEX_HOME="),
                "created codex tab must export CODEX_HOME; got: \(commandLine)")
        #expect(containsCodexProfileLaunch(commandLine),
                "created codex tab must launch codex with the TBD profile; got: \(commandLine)")
        #expect(!commandLine.contains("codex --full-auto"),
                "created codex tab must not use removed --full-auto flag; got: \(commandLine)")
        // The codex session must carry `DISABLE_AUTO_UPDATE=true` in its
        // process environment (set before .zshrc runs) so oh-my-zsh's
        // interactive update prompt can't block the spawned codex command.
        // Read from the job's environment rather than the command line: an
        // `export` there would land only after the rc files had run.
        #expect(launch.request.environment["DISABLE_AUTO_UPDATE"] == "true",
                "codex session must suppress the oh-my-zsh update prompt via its process env; got: \(launch.request.environment)")
    }

    @Test("handleTerminalCreate passes initial prompt to fresh Codex sessions")
    func testHandleTerminalCreateCodexInitialPrompt() async throws {
        let codex = isolateCodexHome(); defer { codex.cleanup() }

        let db = try TBDDatabase(inMemory: true)
        let (router, holder) = makeHolderBackedRouter(db: db)

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

        let terminal = try response.decodeResult(Terminal.self)
        let commandLine = holder.launch(for: terminal.id)?.commandLine ?? ""
        #expect(
            containsCodexProfileLaunch(commandLine)
                && commandLine.contains("'don'\\''t ship regressions'"),
            "fresh codex tab must append the initial prompt as a shell-escaped positional argument; got: \(commandLine)")
    }
}
}
