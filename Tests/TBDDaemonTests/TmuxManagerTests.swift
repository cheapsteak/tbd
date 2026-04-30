import Foundation
import Testing
@testable import TBDDaemonLib

@Test func testServerName() {
    let id = UUID()
    let name = TmuxManager.serverName(forRepoID: id)
    #expect(name.hasPrefix("tbd-"))
    #expect(name.count == 4 + 8) // "tbd-" + 8 hex chars
}

@Test func testServerNameDeterministic() {
    let id = UUID()
    let name1 = TmuxManager.serverName(forRepoID: id)
    let name2 = TmuxManager.serverName(forRepoID: id)
    #expect(name1 == name2)
}

@Test func testNewServerCommand() {
    let args = TmuxManager.newServerCommand(
        server: "tbd-a1b2c3d4",
        session: "main",
        cwd: "/tmp/repo"
    )
    #expect(args.contains("-L"))
    #expect(args.contains("tbd-a1b2c3d4"))
    #expect(args.contains("new-session"))
    #expect(args.contains("-s"))
    #expect(args.contains("main"))
    #expect(args.contains("-c"))
    #expect(args.contains("/tmp/repo"))
    #expect(args.contains("-PF"))
    #expect(args.contains("#{window_id}"))
}

@Test func testHasSessionCommand() {
    let args = TmuxManager.hasSessionCommand(
        server: "tbd-a1b2c3d4",
        session: "main"
    )
    #expect(args.contains("-L"))
    #expect(args.contains("tbd-a1b2c3d4"))
    #expect(args.contains("has-session"))
    #expect(args.contains("-t"))
    #expect(args.contains("main"))
}

@Test func testNewWindowCommand() {
    let args = TmuxManager.newWindowCommand(
        server: "tbd-a1b2c3d4",
        session: "main",
        cwd: "/tmp/worktree",
        shellCommand: "claude --dangerously-skip-permissions"
    )
    #expect(args.contains("-L"))
    #expect(args.contains("tbd-a1b2c3d4"))
    #expect(args.contains("-t"))
    #expect(args.contains("main"))
    #expect(args.contains("-c"))
    #expect(args.contains("/tmp/worktree"))
    #expect(args.contains("claude --dangerously-skip-permissions"))
}

@Test func testKillWindowCommand() {
    let args = TmuxManager.killWindowCommand(
        server: "tbd-a1b2c3d4",
        windowID: "@5"
    )
    #expect(args.contains("-L"))
    #expect(args.contains("tbd-a1b2c3d4"))
    #expect(args.contains("kill-window"))
    #expect(args.contains("-t"))
    #expect(args.contains("@5"))
}

@Test func testSendKeysCommand() {
    let args = TmuxManager.sendKeysCommand(
        server: "tbd-a1b2c3d4",
        paneID: "%3",
        text: "hello world"
    )
    #expect(args.contains("-L"))
    #expect(args.contains("tbd-a1b2c3d4"))
    #expect(args.contains("send-keys"))
    #expect(args.contains("-l"))
    #expect(args.contains("-t"))
    #expect(args.contains("%3"))
    #expect(args.contains("hello world"))
}

@Test func testListWindowsCommand() {
    let args = TmuxManager.listWindowsCommand(
        server: "tbd-a1b2c3d4",
        session: "main"
    )
    #expect(args.contains("-L"))
    #expect(args.contains("tbd-a1b2c3d4"))
    #expect(args.contains("list-windows"))
    #expect(args.contains("-t"))
    #expect(args.contains("main"))
}

@Test func testDryRunCreateWindow() async throws {
    let manager = TmuxManager(dryRun: true)
    let result1 = try await manager.createWindow(
        server: "tbd-test",
        session: "main",
        cwd: "/tmp",
        shellCommand: "echo hi"
    )
    #expect(result1.windowID == "@mock-0")
    #expect(result1.paneID == "%mock-0")

    let result2 = try await manager.createWindow(
        server: "tbd-test",
        session: "main",
        cwd: "/tmp",
        shellCommand: "echo hi"
    )
    #expect(result2.windowID == "@mock-1")
    #expect(result2.paneID == "%mock-1")
}

@Test func testDryRunListWindows() async throws {
    let manager = TmuxManager(dryRun: true)
    let windows = try await manager.listWindows(server: "tbd-test", session: "main")
    #expect(windows.isEmpty)
}

@Test func testDryRunEnsureServer() async throws {
    let manager = TmuxManager(dryRun: true)
    // Should not throw in dry run mode
    try await manager.ensureServer(server: "tbd-test", session: "main", cwd: "/tmp")
}

@Test func testDryRunKillWindow() async throws {
    let manager = TmuxManager(dryRun: true)
    // Should not throw in dry run mode
    try await manager.killWindow(server: "tbd-test", windowID: "@mock-0")
}

@Test func testDryRunSendKeys() async throws {
    let manager = TmuxManager(dryRun: true)
    // Should not throw in dry run mode
    try await manager.sendKeys(server: "tbd-test", paneID: "%mock-0", text: "hello")
}

@Test func capturePaneCommand() {
    let args = TmuxManager.capturePaneCommand(server: "tbd-test", paneID: "%42")
    #expect(args == ["-L", "tbd-test", "capture-pane", "-p", "-t", "%42"])
}

@Test func paneCurrentCommandQuery() {
    let args = TmuxManager.paneCurrentCommandQuery(server: "tbd-test", paneID: "%42")
    #expect(args == ["-L", "tbd-test", "list-panes", "-t", "%42", "-F", "#{pane_current_command}"])
}

@Test func panePIDQuery() {
    let args = TmuxManager.panePIDQuery(server: "tbd-test", paneID: "%42")
    #expect(args == ["-L", "tbd-test", "list-panes", "-t", "%42", "-F", "#{pane_pid}"])
}

@Test func sendCommandWithEnter() {
    let args = TmuxManager.sendCommandArgs(server: "tbd-test", paneID: "%42", command: "/exit")
    #expect(args == ["-L", "tbd-test", "send-keys", "-t", "%42", "/exit", "Enter"])
}

// MARK: - Initial Window Size (cols/rows flags)
//
// Size flags (-x/-y) are emitted only on `new-session` — tmux's `new-window`
// subcommand does not accept them, so we deliberately drop them on the
// new-window path even when callers pass cols/rows. The session's -x/-y from
// `new-session` governs initial size and SwiftTerm's TIOCSWINSZ resizes the
// pane once the client attaches. The tests below cover both branches of the
// new-session size-emission conditional (explicit size emits flags, nil /
// below-minimum size omits them) and confirm new-window never emits them.

@Test func testNewServerCommandWithExplicitSize() {
    let args = TmuxManager.newServerCommand(
        server: "tbd-a1b2c3d4", session: "main", cwd: "/tmp/repo",
        cols: 220, rows: 50
    )
    #expect(args.contains("-x"))
    #expect(args.contains("220"))
    #expect(args.contains("-y"))
    #expect(args.contains("50"))
    // -PF must remain trailing so tmux's positional parsing still works.
    #expect(args.last == "#{window_id}")
    #expect(args[args.count - 2] == "-PF")
}

@Test func testNewServerCommandWithoutSize() {
    let args = TmuxManager.newServerCommand(
        server: "tbd-a1b2c3d4", session: "main", cwd: "/tmp/repo"
    )
    #expect(!args.contains("-x"))
    #expect(!args.contains("-y"))
}

@Test func testNewServerCommandIgnoresBelowMinimumSize() {
    // Floor at 80x24 — anything smaller is silently dropped so tmux uses its
    // own default rather than a degenerate size.
    let args = TmuxManager.newServerCommand(
        server: "tbd-test", session: "main", cwd: "/tmp",
        cols: 40, rows: 10
    )
    #expect(!args.contains("-x"))
    #expect(!args.contains("-y"))
}

@Test func testNewWindowCommandWithExplicitSize() {
    // tmux's `new-window` does NOT accept -x/-y (only `new-session`,
    // `split-window`, `resize-window`, `resize-pane` do). Even when callers
    // pass cols/rows we must NOT emit them — the session's -x/-y from
    // `new-session` sets the initial size and SwiftTerm's TIOCSWINSZ resizes
    // the pane after attach.
    let args = TmuxManager.newWindowCommand(
        server: "tbd-a1b2c3d4", session: "main", cwd: "/tmp/worktree",
        shellCommand: "claude --dangerously-skip-permissions",
        cols: 200, rows: 60
    )
    #expect(!args.contains("-x"))
    #expect(!args.contains("200"))
    #expect(!args.contains("-y"))
    #expect(!args.contains("60"))
    // The shell command must remain at the very end (tmux's last positional
    // arg is the spawn command).
    #expect(args.last == "claude --dangerously-skip-permissions")
}

@Test func testNewWindowCommandWithoutSize() {
    let args = TmuxManager.newWindowCommand(
        server: "tbd-a1b2c3d4", session: "main", cwd: "/tmp/worktree",
        shellCommand: "echo hi"
    )
    #expect(!args.contains("-x"))
    #expect(!args.contains("-y"))
}

@Test func testCreateWindowDryRunDoesNotForwardSize() async throws {
    // `createWindow` ultimately invokes `tmux new-window`, which does not
    // accept -x/-y. Confirm the dry-run argv does NOT include them even when
    // the caller passes cols/rows.
    let recorded = LockedCommandRecorder()
    let manager = TmuxManager(dryRun: true, dryRunRecorder: { args in
        recorded.append(args)
    })
    _ = try await manager.createWindow(
        server: "tbd-test", session: "main", cwd: "/tmp",
        shellCommand: "echo hi", cols: 220, rows: 50
    )
    let calls = recorded.snapshot()
    #expect(calls.count == 1)
    let args = calls[0]
    #expect(args.contains("new-window"))
    #expect(!args.contains("-x"))
    #expect(!args.contains("-y"))
    #expect(!args.contains("220"))
    #expect(!args.contains("50"))
}

@Test func testEnsureServerDryRunForwardsSize() async throws {
    let recorded = LockedCommandRecorder()
    let manager = TmuxManager(dryRun: true, dryRunRecorder: { args in
        recorded.append(args)
    })
    try await manager.ensureServer(
        server: "tbd-test", session: "main", cwd: "/tmp",
        cols: 220, rows: 50
    )
    let calls = recorded.snapshot()
    #expect(calls.count == 1)
    let args = calls[0]
    #expect(args.contains("new-session"))
    #expect(args.contains("-x"))
    #expect(args.contains("220"))
    #expect(args.contains("-y"))
    #expect(args.contains("50"))
}

@Test func testResizeWindowCommand() {
    let args = TmuxManager.resizeWindowCommand(
        server: "tbd-test", windowID: "@5", cols: 240, rows: 80
    )
    #expect(args == ["-L", "tbd-test", "resize-window", "-t", "@5", "-x", "240", "-y", "80"])
}

@Test func testResizeWindowDryRunRecords() async throws {
    let recorded = LockedCommandRecorder()
    let manager = TmuxManager(dryRun: true, dryRunRecorder: { args in
        recorded.append(args)
    })
    try await manager.resizeWindow(server: "tbd-test", windowID: "@5", cols: 240, rows: 80)
    let calls = recorded.snapshot()
    #expect(calls.count == 1)
    #expect(calls[0] == ["-L", "tbd-test", "resize-window", "-t", "@5", "-x", "240", "-y", "80"])
}

/// Thread-safe recorder for dry-run argv captures used by the tests above.
final class LockedCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func append(_ args: [String]) {
        lock.lock(); defer { lock.unlock() }
        calls.append(args)
    }
    func snapshot() -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
}
