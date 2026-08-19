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

@Test func testNewServerCommandSetsHistoryLimitBeforeNewSession() throws {
    // history-limit must be chained BEFORE new-session in the same tmux
    // command list: panes capture their history ceiling at window-creation
    // time, so the option has to be in force before window 0 exists.
    let args = TmuxManager.newServerCommand(
        server: "tbd-a1b2c3d4",
        session: "main",
        cwd: "/tmp/repo"
    )
    let setIdx = try #require(args.firstIndex(of: "set-option"))
    let sepIdx = try #require(args.firstIndex(of: ";"))
    let newIdx = try #require(args.firstIndex(of: "new-session"))
    #expect(Array(args[setIdx..<sepIdx]) == ["set-option", "-g", "history-limit", "50000"])
    #expect(setIdx < sepIdx)
    #expect(sepIdx < newIdx)
    // -PF format spec must remain trailing so tmux positional parsing works.
    #expect(args.last == "#{window_id}")
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

@Test func testTerminalFeaturesHyperlinksCommand() {
    // OSC 8 hyperlinks emitted by Claude Code are stripped by tmux for normal
    // (non-control-mode) attach clients unless the client's TERM advertises the
    // `hyperlinks` terminal-feature. TBD's grouped-sessions attach client runs
    // with TERM=xterm-256color, so server setup must advertise the feature keyed
    // to that TERM for the sequences to reach SwiftTerm.
    let args = TmuxManager.terminalFeaturesHyperlinksCommand(server: "tbd-a1b2c3d4")
    #expect(args == ["-L", "tbd-a1b2c3d4", "set", "-ga", "terminal-features", "xterm-256color:hyperlinks"])
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

@Test func testShellFlagsPerShellFamily() {
    // Each branch of the flag choice, with hardcoded expectations: csh and
    // tcsh reject -l when combined with -c (measured: "Unknown option: `-l'"),
    // so they keep the pre-login-shell -i -c. Every other shell gets the
    // interactive login -i -l -c. Flags are separate argv elements, never
    // clustered, because some shells (e.g. nushell) reject GNU-style
    // clustering while accepting the individual flags.
    #expect(TmuxManager.shellFlags(forShell: "/bin/tcsh") == ["-i", "-c"])
    #expect(TmuxManager.shellFlags(forShell: "/bin/csh") == ["-i", "-c"])
    // The lowercased basename decides, not the full path or its case.
    #expect(TmuxManager.shellFlags(forShell: "/usr/local/bin/tcsh") == ["-i", "-c"])
    #expect(TmuxManager.shellFlags(forShell: "/bin/TCSH") == ["-i", "-c"])
    #expect(TmuxManager.shellFlags(forShell: "/opt/weird/wrappers/deep/path/csh") == ["-i", "-c"])
    #expect(TmuxManager.shellFlags(forShell: "/bin/zsh") == ["-i", "-l", "-c"])
    #expect(TmuxManager.shellFlags(forShell: "/bin/bash") == ["-i", "-l", "-c"])
    #expect(TmuxManager.shellFlags(forShell: "/opt/homebrew/bin/fish") == ["-i", "-l", "-c"])
    // Degenerate paths fall into the default branch rather than crashing.
    #expect(TmuxManager.shellFlags(forShell: "") == ["-i", "-l", "-c"])
    #expect(TmuxManager.shellFlags(forShell: "/") == ["-i", "-l", "-c"])
    #expect(TmuxManager.shellFlags(forShell: "/bin/") == ["-i", "-l", "-c"])
}

@Test func testNewWindowCommandRunsLoginShell() throws {
    // Spawned panes run the user's shell as an interactive LOGIN shell:
    // zsh sources zshenv + zprofile + zshrc; bash login shells source
    // profile files only, relying on the near-universal convention that
    // .bash_profile sources .bashrc (same behavior as Terminal.app).
    // /etc/zprofile's path_helper and ~/.zprofile supply /usr/local/bin and
    // the Homebrew PATH entries; a non-login -i -c shell skips profile files
    // and leaves user tools like `code` unresolvable. The environment seam
    // pins SHELL so the expected argv tail is hardcoded, not derived.
    // See docs/specs/2026-08-19-login-shell-panes-design.md.
    let args = TmuxManager.newWindowCommand(
        server: "tbd-a1b2c3d4",
        session: "main",
        cwd: "/tmp/worktree",
        shellCommand: "claude",
        env: ["TBD_TERMINAL_ID": "abc-123"],
        sensitiveEnv: ["ANTHROPIC_API_KEY": "sk-test"],
        environment: ["SHELL": "/bin/zsh"]
    )
    // The shell invocation is the exact argv tail: shell, separate flags,
    // then the command string as the final positional argument. The env map
    // is inlined as an export prefix on the command string, which runs after
    // every startup file (profile and rc), so it stays the last writer.
    #expect(args.suffix(5) == ["/bin/zsh", "-i", "-l", "-c", "export TBD_TERMINAL_ID='abc-123'; claude"])
    // sensitiveEnv still lands via tmux -e: in the process environment before
    // the shell starts, visible during profile files and rc files alike.
    let eIndex = try #require(args.firstIndex(of: "ANTHROPIC_API_KEY=sk-test"))
    #expect(eIndex > 0)
    #expect(args[eIndex - 1] == "-e")
}

@Test func testNewWindowCommandCshFamilyOmitsLoginFlag() {
    // csh/tcsh reject -l combined with -c, so the csh branch must reach the
    // real builder: pin SHELL to tcsh through the environment seam and assert
    // the hardcoded -i -c tail.
    let args = TmuxManager.newWindowCommand(
        server: "tbd-a1b2c3d4",
        session: "main",
        cwd: "/tmp/worktree",
        shellCommand: "claude",
        environment: ["SHELL": "/bin/tcsh"]
    )
    #expect(args.suffix(4) == ["/bin/tcsh", "-i", "-c", "claude"])
}

@Test func testNewWindowCommandFallsBackToZshWithoutSHELL() {
    // An empty environment (no SHELL) falls back to /bin/zsh.
    let args = TmuxManager.newWindowCommand(
        server: "tbd-a1b2c3d4",
        session: "main",
        cwd: "/tmp/worktree",
        shellCommand: "claude",
        environment: [:]
    )
    #expect(args.suffix(5) == ["/bin/zsh", "-i", "-l", "-c", "claude"])
}

@Test func testRespawnWindowCommandRunsLoginShell() throws {
    // The in-place respawn path (seamless profile swap) must spawn through
    // the same interactive login-shell shape as newWindowCommand, with the
    // same env-prefix and -e handling.
    let args = TmuxManager.respawnWindowCommand(
        server: "tbd-a1b2c3d4",
        windowID: "@5",
        cwd: "/tmp/worktree",
        shellCommand: "claude --resume",
        env: ["CLAUDE_CONFIG_DIR": "/tmp/profile"],
        sensitiveEnv: ["ANTHROPIC_API_KEY": "sk-test"],
        environment: ["SHELL": "/bin/zsh"]
    )
    #expect(args.contains("respawn-window"))
    #expect(args.contains("-k"))
    #expect(args.suffix(5) == ["/bin/zsh", "-i", "-l", "-c", "export CLAUDE_CONFIG_DIR='/tmp/profile'; claude --resume"])
    let eIndex = try #require(args.firstIndex(of: "ANTHROPIC_API_KEY=sk-test"))
    #expect(eIndex > 0)
    #expect(args[eIndex - 1] == "-e")
}

@Test func testRespawnWindowCommandCshFamilyOmitsLoginFlag() {
    // The respawn builder must fork on the same csh branch as
    // newWindowCommand: same seam, same hardcoded -i -c tail.
    let args = TmuxManager.respawnWindowCommand(
        server: "tbd-a1b2c3d4",
        windowID: "@5",
        cwd: "/tmp/worktree",
        shellCommand: "claude --resume",
        environment: ["SHELL": "/bin/tcsh"]
    )
    #expect(args.suffix(4) == ["/bin/tcsh", "-i", "-c", "claude --resume"])
}

@Test func testNewWindowCommandSensitiveEnvUsesEFlag() {
    // sensitiveEnv must land in the process environment via tmux's
    // `-e KEY=VALUE` flag (visible while profile and rc files run), never as
    // an `export` prefix inside the -c command string (which runs after).
    let args = TmuxManager.newWindowCommand(
        server: "tbd-a1b2c3d4",
        session: "main",
        cwd: "/tmp/worktree",
        shellCommand: "echo hi",
        sensitiveEnv: ["DISABLE_AUTO_UPDATE": "true"]
    )
    let index = args.firstIndex(of: "DISABLE_AUTO_UPDATE=true")
    #expect(index != nil)
    if let index, index > 0 {
        #expect(args[index - 1] == "-e")
    }
    #expect(args.last == "echo hi",
            "sensitiveEnv must not be exported inside the shell command")

    // Without sensitiveEnv, no -e flag is emitted at all.
    let plain = TmuxManager.newWindowCommand(
        server: "tbd-a1b2c3d4",
        session: "main",
        cwd: "/tmp/worktree",
        shellCommand: "echo hi"
    )
    #expect(!plain.contains("-e"))
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

@Test func serverPIDQueryShape() {
    #expect(TmuxManager.serverPIDQuery(server: "tbd-abc")
        == ["-L", "tbd-abc", "display-message", "-p", "#{pid}"])
}

@Test func listAllPanePIDsCommandShape() {
    #expect(TmuxManager.listAllPanePIDsCommand(server: "tbd-abc")
        == ["-L", "tbd-abc", "list-panes", "-a", "-F", "#{pane_pid}"])
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

@Test func testCreateWindowDryRunDoesNotForwardSizeOnNewWindow() async throws {
    // `createWindow` ultimately invokes `tmux new-window`, which does not
    // accept -x/-y. Confirm the dry-run argv for new-window does NOT include
    // them even when the caller passes cols/rows. (A separate resize-window
    // invocation should follow — see testCreateWindowEmitsResizeAfterNewWindow.)
    let recorded = LockedCommandRecorder()
    let manager = TmuxManager(dryRun: true, dryRunRecorder: { args in
        recorded.append(args)
    })
    _ = try await manager.createWindow(
        server: "tbd-test", session: "main", cwd: "/tmp",
        shellCommand: "echo hi", cols: 220, rows: 50
    )
    let calls = recorded.snapshot()
    let newWindowCall = calls.first { $0.contains("new-window") }
    #expect(newWindowCall != nil)
    if let args = newWindowCall {
        #expect(!args.contains("-x"))
        #expect(!args.contains("-y"))
        #expect(!args.contains("220"))
        #expect(!args.contains("50"))
    }
}

@Test func testCreateWindowEmitsResizeAfterNewWindow() async throws {
    // Because tmux `new-window` cannot take -x/-y AND the TBD `main` session
    // has no attached client to inherit a size from (we only ever attach to
    // `view-*` grouped sessions), a freshly-created window falls back to
    // tmux's 80x24 default. createWindow must follow up with an explicit
    // `resize-window` to lock in the caller-supplied dimensions, otherwise
    // never-viewed terminals stay stuck at 80x24 with hard-wrapped scrollback.
    let recorded = LockedCommandRecorder()
    let manager = TmuxManager(dryRun: true, dryRunRecorder: { args in
        recorded.append(args)
    })
    let result = try await manager.createWindow(
        server: "tbd-test", session: "main", cwd: "/tmp",
        shellCommand: "echo hi", cols: 220, rows: 50
    )
    let calls = recorded.snapshot()
    #expect(calls.count == 3)
    // Order matters: the new-window must be issued before the resize-window
    // (we can only resize an existing window). The set-option then unfreezes
    // window-size so attached SwiftTerm clients can drive the size.
    #expect(calls[0].contains("new-window"))
    #expect(calls[1] == ["-L", "tbd-test", "resize-window", "-t", result.windowID, "-x", "220", "-y", "50"])
    #expect(calls[2] == ["-L", "tbd-test", "set-option", "-wt", result.windowID, "window-size", "latest"])
}

@Test func testCreateWindowSkipsResizeWhenSizeNil() async throws {
    // No cols/rows → no resize. Just a single new-window invocation.
    let recorded = LockedCommandRecorder()
    let manager = TmuxManager(dryRun: true, dryRunRecorder: { args in
        recorded.append(args)
    })
    _ = try await manager.createWindow(
        server: "tbd-test", session: "main", cwd: "/tmp",
        shellCommand: "echo hi"
    )
    let calls = recorded.snapshot()
    #expect(calls.count == 1)
    #expect(calls[0].contains("new-window"))
    #expect(!calls.contains { $0.contains("resize-window") })
}

@Test func testCreateWindowSkipsResizeBelowMinimum() async throws {
    // Same floor as sizeFlags: anything below 80x24 is dropped so we don't
    // pin the window to a degenerate size. tmux's own default is preferable.
    let recorded = LockedCommandRecorder()
    let manager = TmuxManager(dryRun: true, dryRunRecorder: { args in
        recorded.append(args)
    })
    _ = try await manager.createWindow(
        server: "tbd-test", session: "main", cwd: "/tmp",
        shellCommand: "echo hi", cols: 40, rows: 10
    )
    let calls = recorded.snapshot()
    #expect(calls.count == 1)
    #expect(calls[0].contains("new-window"))
    #expect(!calls.contains { $0.contains("resize-window") })
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
    // Two calls: the resize, then the unfreeze that flips window-size out
    // of manual mode so attached clients can drive it via TIOCSWINSZ.
    #expect(calls.count == 2)
    #expect(calls[0] == ["-L", "tbd-test", "resize-window", "-t", "@5", "-x", "240", "-y", "80"])
    #expect(calls[1] == ["-L", "tbd-test", "set-option", "-wt", "@5", "window-size", "latest"])
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

/// A tmux failure has to survive the trip to a log line.
///
/// `TmuxError.commandFailed` has always carried the tmux subcommand, its exit
/// status and tmux's own stdout/stderr, but the enum conformed to plain `Error`
/// — so every site that formatted it through `localizedDescription` got the
/// `NSError` bridge's "<Module>.<Type> error <caseIndex>" instead, and the
/// payload was thrown away at the point of display. The daemon's create path
/// logs at `.error` and `.debug`/`.info` are not persisted for the daemon
/// subsystem by default, which made that one line the entire diagnostic record.
///
/// These assert on the whole composed sentence a human reads, not on fragments.
@Suite struct TmuxErrorDescriptionTests {
    static let command = "tmux -L tbd-a1b2c3d4 new-window -t main: -c /worktrees/example"

    @Test func commandFailedNamesCommandStatusAndOutput() {
        let error = TmuxError.commandFailed(
            command: Self.command,
            status: 1,
            output: "no server running on /private/tmp/tmux-0/tbd-a1b2c3d4"
        )
        let expected = """
            tmux command failed (exit 1): \(Self.command)
            Output: no server running on /private/tmp/tmux-0/tbd-a1b2c3d4
            """
        // `localizedDescription` deliberately, not `description`: it is the
        // accessor the daemon's log sites use, it exists on every `Error`, and
        // it is the one the `NSError` bridge used to answer with a case index.
        #expect(error.localizedDescription == expected)
        #expect(!error.localizedDescription.contains("TmuxError error"))
    }

    @Test func commandFailedWithSilentTmuxOmitsTheOutputLine() {
        let error = TmuxError.commandFailed(command: Self.command, status: 2, output: "   \n")
        #expect(error.localizedDescription == "tmux command failed (exit 2): \(Self.command)")
    }

    @Test func timedOutNamesCommandAndTimeout() {
        let error = TmuxError.timedOut(command: Self.command, timeout: .seconds(30))
        #expect(
            error.localizedDescription
                == "tmux command timed out after \(Duration.seconds(30)): \(Self.command)")
        // The timeout must be legible as a number of seconds, not an opaque value.
        #expect(error.localizedDescription.contains("30"))
        #expect(!error.localizedDescription.contains("TmuxError error"))
    }

    @Test func unexpectedOutputNamesWhatTmuxSaid() {
        let error = TmuxError.unexpectedOutput("%unknown-directive")
        #expect(error.localizedDescription == "tmux returned unexpected output: %unknown-directive")
        #expect(!error.localizedDescription.contains("TmuxError error"))
    }

    @Test func unexpectedOutputWithNothingToShowSaysSo() {
        #expect(
            TmuxError.unexpectedOutput("").localizedDescription
                == "tmux returned unexpected output: (none)")
    }

    @Test func outputIsKeptWholeUpToTheTruncationBoundary() {
        let output = String(repeating: "x", count: 500)
        let rendered = TmuxError.commandFailed(
            command: Self.command, status: 1, output: output
        ).localizedDescription
        #expect(rendered.hasSuffix("Output: \(output)"))
        #expect(!rendered.contains("…"))
    }

    @Test func outputPastTheBoundaryIsTruncatedWithAnEllipsis() {
        let rendered = TmuxError.commandFailed(
            command: Self.command, status: 1, output: String(repeating: "x", count: 501)
        ).localizedDescription
        #expect(rendered.hasSuffix("Output: \(String(repeating: "x", count: 500))…"))
        // The command stays whole — truncation bounds tmux's output, not the
        // identity of the subcommand that failed.
        #expect(rendered.contains(Self.command))
    }

    /// The daemon's background-create log site formats with `String(describing:)`
    /// so error types it cannot reach still print a payload rather than a case
    /// index. Pin that this renders the same sentence for a tmux failure.
    @Test func stringDescribingRendersTheSameSentence() {
        let error = TmuxError.commandFailed(
            command: Self.command, status: 1, output: "can't find window: main"
        )
        #expect(String(describing: error) == error.localizedDescription)
        #expect(String(describing: error).contains("can't find window: main"))
    }
}
