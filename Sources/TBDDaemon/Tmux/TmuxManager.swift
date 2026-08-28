import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "TmuxManager")

/// What one read-only `list-panes` consultation says about a pane that a send
/// is aimed at. Read before anything is typed; see `paneSendTargetQuery`.
public enum PaneSendTarget: Sendable, Equatable {
    /// tmux cannot find the pane — it, its window, or the whole server is gone.
    case missing
    /// The pane object exists (`remain-on-exit` kept it) but its process has
    /// exited. `send-keys` into it still exits 0 and the keys go nowhere.
    /// `terminalID` carries the same ownership stamp as a live pane so
    /// lifecycle reconciliation can preserve an owned gravestone while still
    /// repairing a recycled coordinate that belongs to another terminal.
    case dead(terminalID: String?)
    /// The pane is alive. `terminalID` is the TBD terminal UUID the pane itself
    /// answered with, or `nil` when the pane carries no identity to compare —
    /// a pane spawned before TBD stamped one, or by something outside TBD.
    case live(terminalID: String?)
}

/// Serializes tmux resource ownership transitions per server.
///
/// A tmux window becomes externally visible before the database row that owns
/// it can commit. Reconciliation has the inverse multi-system transaction: it
/// snapshots database ownership before killing an untracked tmux resource.
/// Both operations use this coordinator so neither can observe the other's
/// half-finished state. Different servers remain independent.
actor TmuxServerResourceCoordinator {
    private var lockedServers: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func withLock<Result: Sendable>(
        server: String,
        operation: @Sendable () async throws -> Result
    ) async rethrows -> Result {
        if lockedServers.contains(server) {
            await withCheckedContinuation { continuation in
                waiters[server, default: []].append(continuation)
            }
        } else {
            lockedServers.insert(server)
        }
        defer { release(server: server) }
        return try await operation()
    }

    private func release(server: String) {
        if var queued = waiters[server], !queued.isEmpty {
            let next = queued.removeFirst()
            waiters[server] = queued.isEmpty ? nil : queued
            next.resume()
        } else {
            lockedServers.remove(server)
        }
    }
}

public struct TmuxManager: Sendable {
    /// Hard ceiling on any single tmux subprocess. tmux control operations
    /// (respawn-window, new-session, kill-window, capture-pane, …) normally
    /// complete in milliseconds; a tmux child still running after this long is
    /// wedged (spawn storm / heavy `claude --resume` under load / a hung
    /// server). Bounding it converts an otherwise-infinite `await` — which
    /// used to hang the wake RPC until the app's 300s ceiling and produced the
    /// "recv timed out after 300s" loop — into a fast, catchable failure that
    /// leaves the hibernated row intact for a later retry. 15s is generous
    /// enough that a merely-slow-but-progressing tmux op still succeeds.
    public static let commandTimeout: Duration = .seconds(15)

    public let dryRun: Bool
    /// Per-instance timeout applied to every external tmux subprocess. Defaults
    /// to `commandTimeout`; tests inject a tiny value to exercise the timeout /
    /// SIGTERM-then-SIGKILL path against a real slow command without waiting 15s.
    let subprocessTimeout: Duration
    private let counter: Counter
    /// Shared by every value-copy of this manager (lifecycle, router, and
    /// hibernation coordinator) so all daemon paths use one lock domain.
    private let resourceCoordinator: TmuxServerResourceCoordinator
    /// Optional test hook that records every dryRun command invocation. When set,
    /// dry-run paths still no-op, but the recorder receives the argv that would
    /// have been passed to tmux. Used by spawn / swap integration tests to assert
    /// command shapes without spawning an actual tmux server.
    public let dryRunRecorder: (@Sendable ([String]) -> Void)?
    /// Optional test hook consulted by `windowExists` in dryRun mode: return
    /// `true` for a window ID to simulate that window having been killed.
    /// Without it, dryRun reports every window as alive, which makes paths
    /// like the pre-session `.paneKilled` short-circuit untestable.
    public let dryRunWindowIsDead: (@Sendable (String) -> Bool)?
    /// Optional test hook consulted by `capturePaneOutput` and
    /// `capturePaneWithAnsi` in dryRun mode:
    /// (server, paneID) → pane text. Without it, dryRun captures return "",
    /// which reads as "pane not ready" to the auto-login pump.
    public let dryRunCapturePane: (@Sendable (String, String) -> String)?
    /// Optional test hook consulted by `listWindows` in dryRun mode:
    /// `(server, session)` → the window/pane pairs to report. Without it,
    /// dryRun reports no windows, which makes reconcile's orphan-window
    /// cleanup pass untestable.
    public let dryRunListWindows: (@Sendable (String, String) -> [(windowID: String, paneID: String)])?
    /// Optional test hook consulted by `listSessions` in dryRun mode:
    /// `server` → the session/attached-client pairs to report. Without it,
    /// dryRun reports no sessions, which makes reconcile's external-attach
    /// (`tbd-ext-*`) reclamation pass untestable.
    public let dryRunListSessions: (@Sendable (String) -> [(name: String, attachedClients: Int)])?
    /// Optional test hook consulted by `paneCurrentCommand` in dryRun mode:
    /// `(server, paneID)` → the command string to report. Without it, dryRun
    /// always reports "zsh" (no claude), which makes the park path's verify-exit
    /// poll always see an immediate polite `/exit` — untestable for the
    /// SIGTERM-fallback branch where claude is still running after the poll.
    public let dryRunPaneCurrentCommand: (@Sendable (String, String) -> String)?
    /// Optional test hook consulted by `createWindow` in dryRun mode: return a
    /// non-nil error for a server name to simulate window creation failing
    /// (tmux refused the new-window, server wedged, …). Without it, dryRun
    /// createWindow always succeeds, which makes the wake path's
    /// recreate-failure branch (`WakeResult.respawnFailed`) untestable.
    public let dryRunCreateWindowError: (@Sendable (String) -> Error?)?
    /// Optional test hook consulted by `respawnWindow` in dryRun mode: return a
    /// non-nil error for a window ID to simulate the respawn failing. Without
    /// it, dryRun respawnWindow always succeeds, which makes the wake path's
    /// respawn-failure branch (`WakeResult.respawnFailed`) untestable.
    public let dryRunRespawnWindowError: (@Sendable (String) -> Error?)?
    /// Optional test hook consulted by `killWindow` in dryRun mode: return a
    /// non-nil error for a `(server, windowID)` pair to simulate the kill
    /// failing (server wedged, window already reaped by someone else, …).
    /// Without it, dryRun killWindow always succeeds, which makes the close
    /// paths' transport-failure branch — the one the actuation record
    /// classifies as `transport-failed` rather than `dispatched` — untestable.
    public let dryRunKillWindowError: (@Sendable (String, String) -> Error?)?
    /// Optional test hook consulted by `paneSendTarget` in dryRun mode:
    /// `(server, paneID)` → what the pane answers. Without it, dryRun reports
    /// `.live(terminalID: nil)` — alive, carrying no identity — which is the
    /// branch that proceeds, so a fixture that never spawned a real pane keeps
    /// behaving exactly as it did before the send path started asking.
    ///
    /// Throwing, because "the consultation could not be run at all" is one of
    /// the answers: it is the wedged-tmux path the send classifies as a
    /// transport failure rather than a refusal, and a non-throwing hook would
    /// leave that branch with no way to be exercised.
    public let dryRunPaneSendTarget: (@Sendable (String, String) throws -> PaneSendTarget)?
    /// Optional test hook consulted by `pasteText` in dryRun mode:
    /// `(server, paneID, bytes)` — the payload that would have been written to
    /// the buffer file. `dryRunRecorder` cannot carry it: the real path passes
    /// the body through a temp FILE, so the recorded argv holds a path and not
    /// one byte of the content. Tests that assert on WHAT was pasted — the
    /// dispatch envelope, for one — need the bytes themselves.
    public let dryRunPasteBytes: (@Sendable (String, String, Data) -> Void)?
    /// Optional test hook for real (non-dryRun) mode: override the result of
    /// `windowExists(server:windowID:)`. Allows tests to force a window as dead
    /// while still having a live process running in the pane (for testing the
    /// safety check in reconcile).
    public let realModeWindowExistsOverride: (@Sendable (String, String) -> Bool?)?
    /// Optional test hook for real (non-dryRun) mode: override the result of
    /// `paneCurrentCommand(server:paneID:)`. Allows tests to return a specific
    /// command string without relying on tmux's actual pane_current_command.
    public let realModePaneCurrentCommandOverride: (@Sendable (String, String) -> String?)?

    /// Whether callers should treat `paneCurrentCommand` as a meaningful
    /// process-liveness signal. Plain dry-run fixtures intentionally return a
    /// synthetic `zsh`; tests that inject `dryRunPaneCurrentCommand` opt back
    /// into command verification.
    var verifiesPaneCurrentCommand: Bool {
        !dryRun || dryRunPaneCurrentCommand != nil
    }

    // Thread-safe counter for generating unique mock IDs
    private final class Counter: Sendable {
        private let _value = OSAllocatedUnfairLock(initialState: 0)

        func next() -> Int {
            _value.withLock { value in
                let current = value
                value += 1
                return current
            }
        }
    }

    public init(dryRun: Bool = false, dryRunRecorder: (@Sendable ([String]) -> Void)? = nil, dryRunWindowIsDead: (@Sendable (String) -> Bool)? = nil, dryRunListWindows: (@Sendable (String, String) -> [(windowID: String, paneID: String)])? = nil, dryRunListSessions: (@Sendable (String) -> [(name: String, attachedClients: Int)])? = nil, dryRunCapturePane: (@Sendable (String, String) -> String)? = nil, dryRunPaneCurrentCommand: (@Sendable (String, String) -> String)? = nil, dryRunCreateWindowError: (@Sendable (String) -> Error?)? = nil, dryRunRespawnWindowError: (@Sendable (String) -> Error?)? = nil, dryRunKillWindowError: (@Sendable (String, String) -> Error?)? = nil, dryRunPaneSendTarget: (@Sendable (String, String) throws -> PaneSendTarget)? = nil, dryRunPasteBytes: (@Sendable (String, String, Data) -> Void)? = nil, realModeWindowExistsOverride: (@Sendable (String, String) -> Bool?)? = nil, realModePaneCurrentCommandOverride: (@Sendable (String, String) -> String?)? = nil, subprocessTimeout: Duration = TmuxManager.commandTimeout) {
        self.dryRun = dryRun
        self.subprocessTimeout = subprocessTimeout
        self.counter = Counter()
        self.resourceCoordinator = TmuxServerResourceCoordinator()
        self.dryRunRecorder = dryRunRecorder
        self.dryRunWindowIsDead = dryRunWindowIsDead
        self.dryRunListWindows = dryRunListWindows
        self.dryRunListSessions = dryRunListSessions
        self.dryRunCapturePane = dryRunCapturePane
        self.dryRunPaneCurrentCommand = dryRunPaneCurrentCommand
        self.dryRunCreateWindowError = dryRunCreateWindowError
        self.dryRunRespawnWindowError = dryRunRespawnWindowError
        self.dryRunKillWindowError = dryRunKillWindowError
        self.dryRunPaneSendTarget = dryRunPaneSendTarget
        self.dryRunPasteBytes = dryRunPasteBytes
        self.realModeWindowExistsOverride = realModeWindowExistsOverride
        self.realModePaneCurrentCommandOverride = realModePaneCurrentCommandOverride
    }

    /// Runs one ownership transition while exclusively holding `server`.
    /// Release is structural, including thrown and cancelled operations.
    func withServerResourceLock<Result: Sendable>(
        server: String,
        operation: @Sendable () async throws -> Result
    ) async rethrows -> Result {
        try await resourceCoordinator.withLock(server: server, operation: operation)
    }

    /// Locks the worktree's current tmux server and revalidates the row after
    /// waiting. Promotion and reconcile can change `tmuxServer` while a caller
    /// is queued; retrying prevents a window from being created on the stale
    /// server after the lock protecting it has already been released.
    func withWorktreeServerLock<Result: Sendable>(
        db: TBDDatabase,
        worktreeID: UUID,
        allowedStatuses: Set<WorktreeStatus>,
        operation: @Sendable (LocalWorktree) async throws -> Result
    ) async throws -> Result {
        while true {
            guard let candidate = try await db.worktrees.getLocal(id: worktreeID) else {
                throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
            }
            guard allowedStatuses.contains(candidate.status) else {
                throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
            }
            let candidateServer = candidate.tmuxServer
            let result: Result? = try await withServerResourceLock(server: candidateServer) {
                guard let current = try await db.worktrees.getLocal(id: worktreeID) else {
                    throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
                }
                guard allowedStatuses.contains(current.status) else {
                    throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
                }
                guard current.tmuxServer == candidateServer else { return nil }
                return try await operation(current)
            }
            if let result { return result }
        }
    }

    // MARK: - Static Command Builders

    /// Derive tmux server name from repo path (stable across DB recreations AND process restarts).
    /// Uses a simple deterministic hash (djb2) — NOT Swift's Hasher which is randomized per process.
    public static func serverName(forRepoPath path: String) -> String {
        var hash: UInt64 = 5381
        for byte in path.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte) // hash * 33 + byte
        }
        let hex = String(hash & 0xFFFFFFFF, radix: 16, uppercase: false)
        return "tbd-\(hex)"
    }

    /// Legacy: derive from UUID (for tests and backwards compat)
    public static func serverName(forRepoID id: UUID) -> String {
        let hex = id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "tbd-\(hex)"
    }

    /// Minimum sane terminal size. Smaller values are ignored — tmux's own
    /// default (80x24) is preferable to a degenerate value.
    public static let minCols: Int = 80
    public static let minRows: Int = 24

    /// Default pane size used when a caller does not supply explicit
    /// dimensions. Larger than tmux's own 80x24 default so Claude doesn't
    /// render into hard-wrapped scrollback that can't be reflowed once a
    /// wider SwiftTerm view attaches.
    public static let defaultCols: Int = 220
    public static let defaultRows: Int = 50

    /// Returns the explicit `-x N -y M` flags to pass to tmux when the caller
    /// supplied a usable size. Returns an empty array when either dimension
    /// is nil or below the minimum, leaving tmux to use its own default.
    private static func sizeFlags(cols: Int?, rows: Int?) -> [String] {
        guard let cols, let rows, cols >= minCols, rows >= minRows else { return [] }
        return ["-x", "\(cols)", "-y", "\(rows)"]
    }

    public static func newServerCommand(server: String, session: String, cwd: String, cols: Int? = nil, rows: Int? = nil) -> [String] {
        // history-limit is chained BEFORE new-session in the same tmux
        // invocation (";" separates commands in one command list). tmux
        // captures a pane's history ceiling at window-creation time, so
        // setting it after windows exist does nothing for them — chaining it
        // first guarantees even window 0, created by new-session at server
        // birth, gets the full limit. The server auto-starts for this list
        // because it contains new-session; set-option -g then runs before any
        // window exists. 50000 matches the control-mode replay capture depth
        // (`capture-pane -S -50000`).
        //
        // Place size flags before -PF so the format spec stays last
        // (consistent with tmux argument-order conventions).
        ["-L", server, "set-option", "-g", "history-limit", "50000", ";",
         "new-session", "-d", "-s", session, "-c", cwd]
            + sizeFlags(cols: cols, rows: rows)
            + ["-PF", "#{window_id}"]
    }

    /// Advertise the `hyperlinks` terminal-feature for TERM=xterm-256color so
    /// tmux forwards OSC 8 hyperlink escape sequences to normal (non-control-mode)
    /// attach clients instead of stripping them. The grouped-sessions attach
    /// client (see `TerminalPanelView.makeViewerEnvironment`) runs with
    /// TERM=xterm-256color, so the feature is keyed to that TERM to match.
    ///
    /// Uses `set -ga` (append) rather than `set -g` (replace): `-g` would
    /// overwrite the whole terminal-features array, dropping tmux's built-in
    /// xterm defaults (clipboard, ccolour, cstyle, focus, title). `-ga` appends,
    /// so those defaults are preserved while hyperlink forwarding is added. tmux
    /// strips OSC 8 hyperlinks for a normal-attach client unless this feature is
    /// advertised.
    public static func terminalFeaturesHyperlinksCommand(server: String) -> [String] {
        ["-L", server, "set", "-ga", "terminal-features", "xterm-256color:hyperlinks"]
    }

    public static func hasSessionCommand(server: String, session: String) -> [String] {
        ["-L", server, "has-session", "-t", session]
    }

    /// Prefix `shellCommand` with one `export KEY='value'; ` per `env` entry,
    /// sorted by key, single-quoting each value with the standard `'\''`
    /// escape for an embedded quote.
    ///
    /// Shared by `newWindowCommand` and `respawnWindowCommand` deliberately.
    /// `resolvePaneTerminalID` reads a pane's identity back out of exactly this
    /// text, anchored on `terminalIDExportAnchor`, and that anchor is only safe
    /// while every spawn path emits the identical shape. Two independently
    /// maintained copies could drift and reopen the forgery hole on one path.
    static func envExportPrefixed(_ shellCommand: String, env: [String: String]) -> String {
        var envPrefix = ""
        for (key, value) in env.sorted(by: { $0.key < $1.key }) {
            let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
            envPrefix += "export \(key)='\(escaped)'; "
        }
        return envPrefix.isEmpty ? shellCommand : "\(envPrefix)\(shellCommand)"
    }

    /// tmux `-e KEY=VALUE` flags, sorted by key. Shared by the two spawn
    /// builders for the same reason as `envExportPrefixed`.
    static func sensitiveEnvFlags(_ sensitiveEnv: [String: String]) -> [String] {
        var eFlags: [String] = []
        for (key, value) in sensitiveEnv.sorted(by: { $0.key < $1.key }) {
            eFlags.append("-e")
            eFlags.append("\(key)=\(value)")
        }
        return eFlags
    }

    /// Shell flags for spawning the user's shell with a command string,
    /// chosen by the shell's lowercased basename (the same derivation as
    /// `CLIInstaller.shellRCAndExport`, so "/bin/TCSH" and wrapper paths
    /// behave consistently across both). Flags are separate argv elements
    /// (`-i -l -c`, never clustered `-ilc`): some shells (e.g. nushell)
    /// accept the individual flags but reject GNU-style clustering, and a
    /// rejected spawn kills every pane silently. csh and tcsh cannot combine
    /// -l with -c at all (tcsh accepts -l only as its sole argument), so
    /// they keep the pre-login-shell `-i -c`; every other shell gets
    /// `-i -l -c` (interactive login shell, see
    /// docs/specs/2026-08-19-login-shell-panes-design.md).
    ///
    /// Measured on this macOS host (2026-08-19), separate flags behaving
    /// identically to the clustered forms:
    ///   zsh  -i -l -c 'echo ok' -> ok, exit 0 (same as -ilc)
    ///   bash -i -l -c 'echo ok' -> ok, exit 0 (same as -ilc)
    ///   dash -i -l -c 'echo ok' -> ok, exit 0 (same as -ilc)
    ///   tcsh -i -c 'echo ok' -> ok, exit 0 (same as -ic);
    ///        tcsh -i -l -c -> exit 1, "Unknown option: `-l'"
    ///   csh  -i -c 'echo ok' -> ok, exit 0 (same as -ic);
    ///        csh  -i -l -c -> exit 1, "Unknown option: `-l'"
    ///   (fish not installed to measure)
    static func shellFlags(forShell shellPath: String) -> [String] {
        let basename = (shellPath as NSString).lastPathComponent.lowercased()
        switch basename {
        case "csh", "tcsh":
            return ["-i", "-c"]
        default:
            return ["-i", "-l", "-c"]
        }
    }

    /// The `[shell] + flags + [command]` argv tail appended by both spawn
    /// builders. Shared for the same drift-hazard reason as
    /// `envExportPrefixed`: `newWindowCommand` and `respawnWindowCommand`
    /// must spawn through the identical shell invocation, and the per-shell
    /// flag choice (`shellFlags(forShell:)`) must not fork between them.
    /// The defaulted `environment` parameter is the test seam for the SHELL
    /// read, matching the `TBDConstants.*(environment:)` idiom.
    static func shellInvocation(
        _ fullCommand: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let userShell = environment["SHELL"] ?? "/bin/zsh"
        return [userShell] + shellFlags(forShell: userShell) + [fullCommand]
    }

    public static func newWindowCommand(server: String, session: String, cwd: String, shellCommand: String, env: [String: String] = [:], sensitiveEnv: [String: String] = [:], cols: Int? = nil, rows: Int? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        // Spawn `shell <flags> <cmd>` (via shellInvocation) so commands with
        // arguments work (e.g. "claude --dangerously-skip-permissions").
        // -i keeps it interactive, -l makes it a login shell, -c runs the
        // command. zsh sources zshenv + zprofile + zshrc; bash login shells
        // source profile files only, relying on the near-universal convention
        // that .bash_profile sources .bashrc (same behavior as Terminal.app).
        // /etc/zprofile's path_helper and ~/.zprofile supply the
        // /usr/local/bin and Homebrew PATH entries; see
        // docs/specs/2026-08-19-login-shell-panes-design.md. csh/tcsh cannot
        // combine -l with -c and keep -i -c (see shellFlags(forShell:)).
        // `environment` is the test seam for the SHELL read; production call
        // sites take the default.
        // After the command exits, the pane closes (tmux default behavior)
        let fullCommand = envExportPrefixed(shellCommand, env: env)
        // `sensitiveEnv` carries values that must be in the spawned window's
        // PROCESS environment before the shell starts, via tmux's -e KEY=VALUE
        // flag — NOT inlined into the shell command argv like `env` above.
        // Two kinds of callers rely on this:
        //   - secrets: keeps the value out of `ps aux` for the long-running
        //     shell/claude process. (The secret still appears briefly in the
        //     tmux invocation's own argv during fork/exec, but tmux re-execs
        //     and its server process does not retain the original argv
        //     visibly.)
        //   - startup-file-affecting toggles (e.g. DISABLE_AUTO_UPDATE on hook
        //     panes): the `env` export-prefix runs after every startup file
        //     (profile and rc) completes, so only -e values are visible while
        //     profile and rc files execute.
        let eFlags = sensitiveEnvFlags(sensitiveEnv)
        // Note: size flags (-x/-y) are intentionally NOT emitted here. tmux's
        // `new-window` does not support those flags (only `new-session`,
        // `split-window`, `resize-window`, and `resize-pane` do). The session's
        // `-x`/`-y` from `new-session` governs the initial size, and once the
        // SwiftTerm client attaches it issues TIOCSWINSZ to resize the pane to
        // the actual viewport. The cols/rows parameters are kept on this
        // function for now since callers still pass them; we just don't emit.
        _ = cols
        _ = rows
        return ["-L", server, "new-window", "-t", session, "-c", cwd]
            + eFlags
            + ["-PF", "#{window_id} #{pane_id}"]
            + shellInvocation(fullCommand, environment: environment)
    }

    /// Respawn (replace the running program of) an existing window's pane
    /// IN PLACE, keeping the same window id and pane id. Shares
    /// `newWindowCommand`'s env handling through `envExportPrefixed` and
    /// `sensitiveEnvFlags` — the `env` map is inlined as an
    /// `export …; ` prefix on the shell command (runs AFTER all startup files,
    /// profile and rc alike), while `sensitiveEnv` is passed via tmux
    /// `-e KEY=VALUE` so it's in the process environment before the shell
    /// starts (kept out of `ps aux`, and visible during profile and rc
    /// execution). Spawns the same interactive login-shell invocation as
    /// `newWindowCommand` via `shellInvocation` (zsh sources
    /// zshenv + zprofile + zshrc; bash login shells source profile files
    /// only, relying on .bash_profile sourcing .bashrc; csh/tcsh keep -i -c,
    /// see `shellFlags(forShell:)`). `-k` kills the pane's current program
    /// first. `environment` is the test seam for the SHELL read; production
    /// call sites take the default.
    ///
    /// Used by the seamless in-place account switch: same tab, same terminal
    /// row, new profile's `claude --resume` command. See PR 5222a79 for why the
    /// env re-export must be re-applied on respawn (the original pane env does
    /// not carry over to the newly-exec'd program).
    public static func respawnWindowCommand(
        server: String,
        windowID: String,
        cwd: String,
        shellCommand: String,
        env: [String: String] = [:],
        sensitiveEnv: [String: String] = [:],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let fullCommand = envExportPrefixed(shellCommand, env: env)
        let eFlags = sensitiveEnvFlags(sensitiveEnv)
        return ["-L", server, "respawn-window", "-k", "-t", windowID, "-c", cwd]
            + eFlags
            + shellInvocation(fullCommand, environment: environment)
    }

    /// Resize an existing tmux window to the given cell dimensions.
    public static func resizeWindowCommand(server: String, windowID: String, cols: Int, rows: Int) -> [String] {
        ["-L", server, "resize-window", "-t", windowID, "-x", "\(cols)", "-y", "\(rows)"]
    }

    /// Switch a window out of `window-size manual` mode so attached clients
    /// can drive the size via their own TIOCSWINSZ. tmux's `resize-window`
    /// implicitly sets manual mode, which freezes the window at that size
    /// and prevents SwiftTerm's per-pane ioctl from shrinking it back when
    /// the actual rendered area is smaller than the broadcast measurement.
    public static func setWindowSizeLatestCommand(server: String, windowID: String) -> [String] {
        ["-L", server, "set-option", "-wt", windowID, "window-size", "latest"]
    }

    public static func killWindowCommand(server: String, windowID: String) -> [String] {
        ["-L", server, "kill-window", "-t", windowID]
    }

    public static func sendKeysCommand(server: String, paneID: String, text: String) -> [String] {
        ["-L", server, "send-keys", "-l", "-t", paneID, text]
    }

    /// Send a tmux key name (e.g. "Enter", "Escape") without the -l (literal) flag.
    public static func sendKeyCommand(server: String, paneID: String, key: String) -> [String] {
        ["-L", server, "send-keys", "-t", paneID, key]
    }

    /// Load a temp file's bytes into a uniquely named tmux paste buffer. The
    /// path is passed as a distinct argv element (no shell), so spaces are safe.
    public static func loadBufferCommand(server: String, bufferName: String, path: String) -> [String] {
        ["-L", server, "load-buffer", "-b", bufferName, path]
    }

    /// Paste a named buffer into a pane WITH `-p` (bracketed-paste authority
    /// handed to tmux) and `-d` (delete the buffer after pasting). tmux wraps
    /// the payload in `ESC[200~`/`ESC[201~` iff the pane has bracketed-paste
    /// mode enabled — which agent TUIs (Claude Code, Codex) AND modern
    /// interactive shells (zsh, bash ≥4.4, fish) all do at their prompt — and
    /// emits bare bytes otherwise (a cooked-mode consumer, e.g. a program
    /// reading stdin). Note `-d`/no-`-r`: like the GUI `PasteExecutor` path,
    /// tmux replaces interior LF with CR in the pasted body; this is the proven
    /// paste behavior we deliberately match, and is inside the brackets so it
    /// does not affect the separate trailing Enter.
    public static func pasteBufferCommand(server: String, bufferName: String, paneID: String) -> [String] {
        ["-L", server, "paste-buffer", "-d", "-p", "-b", bufferName, "-t", paneID]
    }

    /// Delete a named paste buffer (best-effort cleanup when `paste-buffer -d`
    /// never ran because the paste itself failed).
    public static func deleteBufferCommand(server: String, bufferName: String) -> [String] {
        ["-L", server, "delete-buffer", "-b", bufferName]
    }

    public static func listWindowsCommand(server: String, session: String) -> [String] {
        ["-L", server, "list-windows", "-t", session, "-F", "#{window_id} #{pane_id}"]
    }

    /// Sessions on a server with each one's attached-client count.
    ///
    /// The count leads the name deliberately: a tmux session name may contain
    /// a space, so the parser splits once on the first separator and takes the
    /// whole remainder as the name. With the name first, a session called
    /// `my session` would parse as a name of `my` and a client count of
    /// `session`.
    public static func listSessionsCommand(server: String) -> [String] {
        ["-L", server, "list-sessions", "-F", "#{session_attached} #{session_name}"]
    }

    public static func killSessionCommand(server: String, session: String) -> [String] {
        ["-L", server, "kill-session", "-t", session]
    }

    public static func capturePaneCommand(server: String, paneID: String) -> [String] {
        ["-L", server, "capture-pane", "-p", "-t", paneID]
    }

    /// Capture pane content with ANSI escape sequences and joined wrapped lines preserved.
    public static func capturePaneWithAnsiCommand(server: String, paneID: String) -> [String] {
        ["-L", server, "capture-pane", "-p", "-e", "-J", "-t", paneID]
    }

    /// Scrollback capture with ANSI (`-e`) escapes preserved, bounded to
    /// roughly the last 10k lines, wrapped lines joined. Used for the archival
    /// closed-terminal-history snapshot taken just before a window is killed.
    /// The escapes are kept so the raw file is a faithful replay source (the
    /// revive path `cat`s it back with colors intact); the read-only viewer
    /// strips them for plain-text display.
    public static func capturePaneScrollbackCommand(server: String, paneID: String) -> [String] {
        ["-L", server, "capture-pane", "-p", "-e", "-J", "-S", "-10000", "-t", paneID]
    }

    /// Keep a window's pane around (marked dead) after its process exits,
    /// instead of destroying the window. Same option TmuxBridge sets
    /// app-side when a viewer attaches.
    public static func setRemainOnExitCommand(server: String, windowID: String) -> [String] {
        ["-L", server, "set-option", "-wt", windowID, "remain-on-exit", "on"]
    }

    public static func paneCurrentCommandQuery(server: String, paneID: String) -> [String] {
        ["-L", server, "list-panes", "-t", paneID, "-F", "#{pane_current_command}"]
    }

    /// The pane option TBD stamps with a terminal's UUID at spawn, so a later
    /// send can ask the pane who it is. `@`-prefixed names are tmux's own
    /// namespace for user options; the value is per-pane and freed with the
    /// pane, which is what makes a *reused* pane id answer empty rather than
    /// with its predecessor's identity.
    public static let terminalIDPaneOption = "@tbd_terminal_id"

    /// Stamp `terminalID` onto a pane so it can identify itself later.
    ///
    /// `target` may be a pane id or a window id — tmux resolves a window target
    /// to that window's active pane. The window form is only used right after a
    /// `respawn-window -k`, which collapses the window to its original single
    /// pane, so "active pane" is unambiguously the terminal's own pane even if
    /// the user had split it by hand a moment earlier.
    public static func setPaneTerminalIDCommand(
        server: String, target: String, terminalID: String
    ) -> [String] {
        ["-L", server, "set-option", "-p", "-t", target, terminalIDPaneOption, terminalID]
    }

    /// Separator between the four fields of `paneSendTargetQuery`.
    ///
    /// A tab: neither a pane id, nor `0`/`1`, nor a UUID can contain one, and
    /// the only field that could — the start command — is last, so it takes the
    /// remainder of the line rather than being split.
    static let paneSendTargetSeparator: Character = "\t"

    /// One read-only consultation answering everything a send needs to know
    /// about its target: does the pane exist, is its process still alive, and
    /// which TBD terminal does the pane itself say it belongs to.
    ///
    /// `list-panes` rather than `display-message`: it exits non-zero with
    /// `can't find pane: %N` when the pane, its window, or the server is gone,
    /// whereas `display-message -p` prints an empty line and exits 0 — which
    /// would report a vanished pane as a healthy one. It is also the primitive
    /// the sibling pane queries above already use.
    ///
    /// `#{pane_id}` leads the format because `list-panes -t %N` does NOT list
    /// only `%N`: it lists every pane in `%N`'s **window**, `%N` merely picking
    /// the window. A TBD window normally holds one pane, but a user can split
    /// one by hand at any time, and then the first line answers for a pane the
    /// send never named — a stranger's `pane_dead` and a stranger's identity,
    /// which is precisely a false refusal. So the line is selected by pane id
    /// rather than by position; see `parsePaneSendTarget`.
    public static func paneSendTargetQuery(server: String, paneID: String) -> [String] {
        ["-L", server, "list-panes", "-t", paneID, "-F",
         "#{pane_id}\(paneSendTargetSeparator)"
         + "#{pane_dead}\(paneSendTargetSeparator)"
         + "#{\(terminalIDPaneOption)}\(paneSendTargetSeparator)"
         + "#{pane_start_command}"]
    }

    /// Classify `paneSendTargetQuery`'s stdout for the pane the send named.
    /// Pure, so the classification is unit-testable without a tmux server.
    ///
    /// Only the line whose `#{pane_id}` is `paneID` counts — the query returns
    /// one line per pane in the target's window. A run with no such line means
    /// tmux answered about a window that no longer holds this pane, which is
    /// the same fact as `can't find pane`: `.missing`.
    static func parsePaneSendTarget(_ output: String, paneID: String) -> PaneSendTarget {
        for line in output.split(separator: "\n") {
            let fields = line.split(
                separator: paneSendTargetSeparator, maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4 else { continue }
            guard fields[0].trimmingCharacters(in: .whitespaces) == paneID else { continue }
            let terminalID = resolvePaneTerminalID(
                paneOption: String(fields[2]), startCommand: String(fields[3]))
            if fields[1].trimmingCharacters(in: .whitespaces) == "1" {
                return .dead(terminalID: terminalID)
            }
            return .live(terminalID: terminalID)
        }
        // rc 0 but no line for this pane (including no output at all): nothing
        // answered for the coordinate the send named.
        return .missing
    }

    /// The exact assignment shape `newWindowCommand` and `respawnWindowCommand`
    /// emit for one entry of the `env` map. Both build the prefix from the one
    /// shared `envExportPrefixed`, so a pane spawned either way — including the
    /// in-place profile swap — carries this literal.
    static let terminalIDExportAnchor = "export TBD_TERMINAL_ID='"

    /// Which TBD terminal a pane says it is, or nil when the pane carries no
    /// answer at all.
    ///
    /// Two sources, in order. The `@tbd_terminal_id` pane option is stamped by
    /// `createWindow`/`respawnWindow`. The fallback reads the same id back out
    /// of `#{pane_start_command}`, because TBD plants `TBD_TERMINAL_ID` through
    /// the `env` map and `newWindowCommand` inlines that map as an
    /// `export KEY='value'; ` prefix on the command string — so every pane
    /// spawned before the option existed still carries its own id. macOS forbids
    /// reading another process's environment (SIP), so the start command, not
    /// `ps eww`, is where the planted value remains legible.
    ///
    /// The fallback is deliberately narrow, because the start command also
    /// carries *user-authored free text*: the env map is inlined sorted by key,
    /// and `TBD_PROMPT_INSTRUCTIONS` — a repo's custom instructions — sorts
    /// before `TBD_TERMINAL_ID` and so appears earlier in the same string. A
    /// bare `TBD_TERMINAL_ID=` substring search would read whatever the user
    /// happened to write as the pane's identity, and a pane that misreports its
    /// identity is refused as a stranger for the whole life of its window. So
    /// the search anchors on the full assignment TBD actually emits, and the
    /// extracted value must parse as a `UUID` — the only thing TBD ever plants
    /// there. Anything else resolves to nil, which means "no answer" and lets
    /// the send proceed.
    ///
    /// Every occurrence of the anchor is scanned rather than just the first, so
    /// a decoy anchor earlier in the string is stepped over and the real id
    /// further along still resolves.
    ///
    /// What a decoy anchor sitting inside an env *value* actually yields is
    /// worth stating exactly, because it is never the decoy's own payload.
    /// `envExportPrefixed` escapes an embedded `'` as `'\''`, so instructions
    /// reading `export TBD_TERMINAL_ID='decoy'` are emitted as
    /// `export TBD_TERMINAL_ID='\''decoy'\''`: the anchor consumes that first
    /// quote and the value read is everything up to the next quote — a lone
    /// backslash. A decoy that instead ends the env entry right at the `=`
    /// reads as the `; export …=` text that always follows the entry's closing
    /// quote. Neither parses as a `UUID`, so the scan steps past and finds the
    /// real id. That guarantee comes from the escaping, not from the resolver,
    /// which is why the two must stay coupled — see `envExportPrefixed`.
    ///
    /// Residual adversarial case: an *unescaped* complete
    /// `export TBD_TERMINAL_ID='<valid uuid>'` earlier in the start command
    /// would be read first. No `env` value can produce one, per the escaping
    /// above, so it would have to arrive through `shellCommand` itself. And it
    /// can only cause a false *refusal* of a healthy pane, never a false
    /// *accept* — a stranger's pane cannot be made to answer with this
    /// terminal's id, and the false accept is the direction that would actually
    /// type into someone else's composer.
    static func resolvePaneTerminalID(paneOption: String, startCommand: String) -> String? {
        let stamped = paneOption.trimmingCharacters(in: .whitespaces)
        if !stamped.isEmpty { return stamped }

        var searchFrom = startCommand.startIndex
        while let anchor = startCommand.range(
            of: terminalIDExportAnchor, range: searchFrom..<startCommand.endIndex) {
            searchFrom = anchor.upperBound
            let rest = startCommand[anchor.upperBound...]
            // No closing quote anywhere after this anchor means no later
            // occurrence can be well-formed either.
            guard let close = rest.firstIndex(of: "'") else { return nil }
            let value = String(rest[..<close])
            if UUID(uuidString: value) != nil { return value }
        }
        return nil
    }

    public static func panePIDQuery(server: String, paneID: String) -> [String] {
        ["-L", server, "list-panes", "-t", paneID, "-F", "#{pane_pid}"]
    }

    public static func paneCurrentPathQuery(server: String, paneID: String) -> [String] {
        ["-L", server, "list-panes", "-t", paneID, "-F", "#{pane_current_path}"]
    }

    /// "1" when the pane is in a mode (copy-mode/scrollback), else "0".
    public static func paneInModeQuery(server: String, paneID: String) -> [String] {
        ["-L", server, "display-message", "-p", "-t", paneID, "#{pane_in_mode}"]
    }

    public static func serverPIDQuery(server: String) -> [String] {
        ["-L", server, "display-message", "-p", "#{pid}"]
    }

    public static func listAllPanePIDsCommand(server: String) -> [String] {
        ["-L", server, "list-panes", "-a", "-F", "#{pane_pid}"]
    }

    /// send-keys without -l so "Enter" is interpreted as a key name, not literal text.
    public static func sendCommandArgs(server: String, paneID: String, command: String) -> [String] {
        ["-L", server, "send-keys", "-t", paneID, command, "Enter"]
    }

    // MARK: - Instance Execution Methods

    /// Ensures a tmux server and session exist.
    /// - Returns: The initial window ID if a new session was created (caller should kill it after
    ///   creating real windows), or `nil` if the session already existed.
    @discardableResult
    public func ensureServer(server: String, session: String, cwd: String, cols: Int? = nil, rows: Int? = nil) async throws -> String? {
        if dryRun {
            // Even in dry-run, still record the new-session shape so tests can
            // assert that size flags propagate.
            let args = Self.newServerCommand(server: server, session: session, cwd: cwd, cols: cols, rows: rows)
            dryRunRecorder?(args)
            return nil
        }
        // Check if the session already exists before creating
        let hasSessionArgs = Self.hasSessionCommand(server: server, session: session)
        do {
            try await runTmux(hasSessionArgs)
            // Session already exists. Ensure hyperlink forwarding is enabled even on
            // servers created before this option existed (tmux servers persist across
            // app restarts). Uses `set -ga` to append so tmux's default xterm
            // features (clipboard, focus, title, etc.) are preserved; OSC 8
            // hyperlinks are stripped for a normal-attach client unless advertised.
            _ = try? await runTmux(Self.terminalFeaturesHyperlinksCommand(server: server))
            return nil
        } catch {
            // Session does not exist, create it — capture the initial window ID
            let args = Self.newServerCommand(server: server, session: session, cwd: cwd, cols: cols, rows: rows)
            let output = try await runTmux(args)
            logger.info("ensureServer: created tmux server \(server, privacy: .public)")
            // Hide tmux chrome globally — TBD app provides its own UI
            _ = try? await runTmux(["-L", server, "set", "-g", "status", "off"])
            _ = try? await runTmux(["-L", server, "set", "-g", "pane-border-style", "fg=black"])
            _ = try? await runTmux(["-L", server, "set", "-g", "pane-border-indicators", "off"])
            _ = try? await runTmux(["-L", server, "set", "-g", "default-terminal", "xterm-256color"])
            // Advertise the `hyperlinks` terminal-feature so tmux forwards OSC 8
            // hyperlink escape sequences to normal (non-control-mode) attach
            // clients instead of stripping them (see helper doc comment).
            _ = try? await runTmux(Self.terminalFeaturesHyperlinksCommand(server: server))
            // Enable mouse so scroll wheel enters copy-mode and scrolls history
            _ = try? await runTmux(["-L", server, "set", "-g", "mouse", "on"])
            // Enable extended key sequences so Shift+Arrow etc. pass through to applications
            _ = try? await runTmux(["-L", server, "set", "-g", "xterm-keys", "on"])
            // Enable Kitty keyboard protocol so apps can distinguish Shift+Enter from Enter
            _ = try? await runTmux(["-L", server, "set", "-g", "extended-keys", "on"])
            _ = try? await runTmux(["-L", server, "set", "-g", "extended-keys-format", "kitty"])
            // Set SSH_AUTH_SOCK to stable symlink so shells get a resilient path
            _ = try? await runTmux(["-L", server, "setenv", "-g", "SSH_AUTH_SOCK", SSHAgentResolver.defaultSymlinkPath])
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Set a global environment variable in a tmux server (all panes inherit it).
    public func setGlobalEnv(server: String, name: String, value: String) async throws {
        if dryRun { return }
        logger.debug("setGlobalEnv: setting \(name, privacy: .public)=\(value, privacy: .public) on server \(server, privacy: .public)")
        try await runTmux(["-L", server, "setenv", "-g", name, value])
    }

    /// Kills an entire tmux server and all its sessions.
    public func killServer(server: String) async throws {
        if dryRun {
            dryRunRecorder?(["-L", server, "kill-server"])
            return
        }
        logger.info("killServer: killing tmux server \(server, privacy: .public)")
        try await runTmux(["-L", server, "kill-server"])
    }

    public func createWindow(server: String, session: String, cwd: String, shellCommand: String, env: [String: String] = [:], sensitiveEnv: [String: String] = [:], cols: Int? = nil, rows: Int? = nil) async throws -> (windowID: String, paneID: String) {
        let result: (windowID: String, paneID: String)
        if dryRun {
            let args = Self.newWindowCommand(server: server, session: session, cwd: cwd, shellCommand: shellCommand, env: env, sensitiveEnv: sensitiveEnv, cols: cols, rows: rows)
            dryRunRecorder?(args)
            if let error = dryRunCreateWindowError?(server) { throw error }
            let n = counter.next()
            result = (windowID: "@mock-\(n)", paneID: "%mock-\(n)")
        } else {
            let args = Self.newWindowCommand(server: server, session: session, cwd: cwd, shellCommand: shellCommand, env: env, sensitiveEnv: sensitiveEnv, cols: cols, rows: rows)
            let output = try await runTmux(args)
            let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            guard parts.count == 2 else {
                throw TmuxError.unexpectedOutput(output)
            }
            result = (windowID: String(parts[0]), paneID: String(parts[1]))
        }

        // Label the pane with the terminal it was spawned for, so a later send
        // can ask the pane who it is instead of trusting a DB coordinate.
        await stampTerminalID(
            server: server, target: result.paneID, env: env, sensitiveEnv: sensitiveEnv)

        // tmux's `new-window` does NOT accept -x/-y, and a freshly-created
        // window inherits its size from the session's attached client. The TBD
        // `main` session has no attached clients (we only ever attach to
        // grouped `view-*` sessions), so tmux falls back to its 80x24 default
        // for the new window — leaving never-viewed terminals frozen at that
        // size with permanent hard-wraps in scrollback. Issue an explicit
        // `resize-window` immediately after creation to lock in the requested
        // size. Failures here are non-fatal: the window itself was created
        // successfully, so we log a warning and continue.
        if let cols, let rows, cols >= Self.minCols, rows >= Self.minRows {
            do {
                try await resizeWindow(server: server, windowID: result.windowID, cols: cols, rows: rows)
            } catch {
                logger.warning("resize-window after createWindow failed for \(result.windowID, privacy: .public) on server \(server, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return result
    }

    /// Respawn a window's pane in place (same window id / pane id) with a new
    /// program. See `respawnWindowCommand` for the env-inlining semantics.
    /// After respawn, re-issues the size lock (mirrors `createWindow`) so the
    /// replaced pane keeps the requested cell dimensions.
    public func respawnWindow(
        server: String,
        windowID: String,
        cwd: String,
        shellCommand: String,
        env: [String: String] = [:],
        sensitiveEnv: [String: String] = [:],
        cols: Int? = nil,
        rows: Int? = nil
    ) async throws {
        let args = Self.respawnWindowCommand(
            server: server, windowID: windowID, cwd: cwd,
            shellCommand: shellCommand, env: env, sensitiveEnv: sensitiveEnv
        )
        if dryRun {
            dryRunRecorder?(args)
            if let error = dryRunRespawnWindowError?(windowID) { throw error }
            await stampTerminalID(
                server: server, target: windowID, env: env, sensitiveEnv: sensitiveEnv)
            return
        }
        try await runTmux(args)
        // Re-stamp: the pane object survives `respawn-window -k` (and so does an
        // earlier stamp), but a respawn is also how a window acquires a program
        // it did not spawn with, so the label is refreshed from the env that
        // actually launched it. A window target resolves to its single pane.
        await stampTerminalID(
            server: server, target: windowID, env: env, sensitiveEnv: sensitiveEnv)
        if let cols, let rows, cols >= Self.minCols, rows >= Self.minRows {
            do {
                try await resizeWindow(server: server, windowID: windowID, cols: cols, rows: rows)
            } catch {
                logger.warning("resize-window after respawnWindow failed for \(windowID, privacy: .public) on server \(server, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func killWindow(server: String, windowID: String) async throws {
        let args = Self.killWindowCommand(server: server, windowID: windowID)
        if dryRun {
            dryRunRecorder?(args)
            if let error = dryRunKillWindowError?(server, windowID) { throw error }
            return
        }
        try await runTmux(args)
    }

    /// Resize an existing tmux window. Used by the main-window resize
    /// broadcast and after `new-window`, so detached panes get a sensible
    /// cell size before any SwiftTerm client attaches. Each call is paired
    /// with `set-option ... window-size latest` to immediately leave manual
    /// size mode — otherwise tmux pins the window at the broadcast value
    /// and an attached SwiftTerm client (whose actual pane is usually
    /// smaller after accounting for tab bars, dividers, file panels, etc.)
    /// can't shrink it back, clipping the bottom rows.
    public func resizeWindow(server: String, windowID: String, cols: Int, rows: Int) async throws {
        let resizeArgs = Self.resizeWindowCommand(server: server, windowID: windowID, cols: cols, rows: rows)
        let unfreezeArgs = Self.setWindowSizeLatestCommand(server: server, windowID: windowID)
        if dryRun {
            dryRunRecorder?(resizeArgs)
            dryRunRecorder?(unfreezeArgs)
            return
        }
        try await runTmux(resizeArgs)
        // Best-effort: the resize itself succeeded, so don't fail the call
        // if the option flip stumbles. Detached panes still keep the
        // resize-window dimensions; only client-driven re-sizing depends on
        // window-size being non-manual.
        _ = try? await runTmux(unfreezeArgs)
    }

    public func sendKeys(server: String, paneID: String, text: String) async throws {
        let args = Self.sendKeysCommand(server: server, paneID: paneID, text: text)
        if dryRun {
            dryRunRecorder?(args)
            return
        }
        try await runTmux(args)
    }

    public func sendKey(server: String, paneID: String, key: String) async throws {
        let args = Self.sendKeyCommand(server: server, paneID: paneID, key: key)
        if dryRun {
            dryRunRecorder?(args)
            return
        }
        try await runTmux(args)
    }

    /// Deliver `bytes` to a pane as an EXPLICIT bracketed paste over the plain
    /// `tmux -L` subprocess path: write to a temp file, `load-buffer` it into a
    /// uniquely named buffer, then `paste-buffer -d -p` into the pane. tmux
    /// surrounds the payload with `ESC[200~`/`ESC[201~` iff the pane enabled
    /// bracketed-paste mode (agent TUIs), and emits bare bytes for plain shells
    /// — so a subsequent separate `Enter` keystroke lands provably OUTSIDE the
    /// paste and can't be absorbed by a TUI's paste-burst coalescing window
    /// (the root cause of `--submit` silently dropping large messages).
    ///
    /// Mirrors `PasteExecutor.paste` (the GUI paste path) but over `runTmux`
    /// rather than the `-CC` control command client, so it stays consistent with
    /// `handleTerminalSend`'s existing plain-subprocess tmux usage and adds no
    /// coupling to control mode. The temp file is removed in all paths; a paste
    /// failure best-effort deletes the orphaned buffer before rethrowing so the
    /// caller surfaces the error.
    public func pasteText(server: String, paneID: String, bytes: Data) async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-paste-\(UUID().uuidString)")
        let path = tempURL.path
        // Note: no quote/newline guard is needed here (unlike PasteExecutor,
        // which single-quotes the path INTO a tmux command string). `runTmux`
        // passes `path` as a distinct argv element with no shell, so any bytes
        // in a FileManager temp path are safe.
        // Unique buffer per call so concurrent pastes never clobber each other.
        let bufferName = "tbd-paste-\(UUID().uuidString.prefix(8))"
        let loadArgs = Self.loadBufferCommand(server: server, bufferName: bufferName, path: path)
        let pasteArgs = Self.pasteBufferCommand(server: server, bufferName: bufferName, paneID: paneID)

        if dryRun {
            // Record the intended argv without touching the filesystem — plus
            // the payload, which the argv cannot carry (it names a temp file).
            dryRunRecorder?(loadArgs)
            dryRunRecorder?(pasteArgs)
            dryRunPasteBytes?(server, paneID, bytes)
            return
        }

        // Register cleanup BEFORE the write so a mid-write throw still removes
        // any partial temp file (PasteExecutor's "removed in all paths").
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try bytes.write(to: tempURL)

        try await runTmux(loadArgs)
        do {
            try await runTmux(pasteArgs)
        } catch {
            // load-buffer succeeded but paste-buffer threw (e.g. the pane died
            // between the two awaits). `-d` would have deleted the buffer on
            // success; since it didn't run, best-effort delete before rethrowing
            // so the uniquely named buffer doesn't linger on the server.
            do {
                try await runTmux(Self.deleteBufferCommand(server: server, bufferName: bufferName))
            } catch let cleanupError {
                logger.debug("""
                    delete-buffer cleanup failed for \(bufferName, privacy: .public): \
                    \(String(describing: cleanupError), privacy: .public) — the buffer may \
                    linger on the tmux server (original paste error is rethrown)
                    """)
            }
            throw error
        }
    }

    public func capturePaneOutput(server: String, paneID: String) async throws -> String {
        if dryRun { return dryRunCapturePane?(server, paneID) ?? "" }
        let args = Self.capturePaneCommand(server: server, paneID: paneID)
        return try await runTmux(args)
    }

    /// Capture pane content with ANSI escape sequences preserved for snapshot display.
    public func capturePaneWithAnsi(server: String, paneID: String) async throws -> String {
        // dryRun consults the same capture hook as `capturePaneOutput` so tests
        // can exercise the park path's snapshot capture end-to-end.
        if dryRun { return dryRunCapturePane?(server, paneID) ?? "" }
        let args = Self.capturePaneWithAnsiCommand(server: server, paneID: paneID)
        return try await runTmux(args)
    }

    /// Set `remain-on-exit on` for a window so its pane survives (dead) when
    /// the process exits. The auto-close setup spawn needs this: its wrapper
    /// lets the pane exit on hook success, and without remain-on-exit the
    /// window is destroyed before the teardown can capture its scrollback.
    public func setRemainOnExit(server: String, windowID: String) async throws {
        let args = Self.setRemainOnExitCommand(server: server, windowID: windowID)
        if dryRun {
            dryRunRecorder?(args)
            return
        }
        try await runTmux(args)
    }

    /// Archival snapshot of a closing pane's scrollback (plain text, last
    /// ~10k lines) for read-only closed-terminal history. Verbatim
    /// pass-through for display — never parsed for agent/TUI state. dryRun
    /// consults the shared `dryRunCapturePane` hook like the other captures.
    public func capturePaneScrollback(server: String, paneID: String) async throws -> String {
        if dryRun { return dryRunCapturePane?(server, paneID) ?? "" }
        let args = Self.capturePaneScrollbackCommand(server: server, paneID: paneID)
        return try await runTmux(args)
    }

    public func paneCurrentCommand(server: String, paneID: String) async throws -> String {
        if dryRun { return dryRunPaneCurrentCommand?(server, paneID) ?? "zsh" }
        if let override = realModePaneCurrentCommandOverride?(server, paneID) {
            return override
        }
        let args = Self.paneCurrentCommandQuery(server: server, paneID: paneID)
        return try await runTmux(args).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ask a pane, before anything is typed into it, whether it exists, whether
    /// its process is alive, and which TBD terminal it belongs to.
    ///
    /// Read-only — a query, not an actuation. Throws only when the query itself
    /// could not be *run*: a wedged server tripping the subprocess timeout
    /// (`TmuxError.timedOut`) or a tmux that would not spawn at all, neither of
    /// which this catch matches. A non-zero *exit* is read as an answer instead,
    /// because the only way this fixed argv can exit non-zero is tmux failing to
    /// resolve the target — `can't find pane`, or no server on that socket, both
    /// of which mean the same thing for a send. (`paneSendTargetQuery`'s exact
    /// argv is pinned by a unit test, so it cannot drift into a usage error that
    /// would arrive here wearing the same clothes.)
    public func paneSendTarget(server: String, paneID: String) async throws -> PaneSendTarget {
        if dryRun { return try dryRunPaneSendTarget?(server, paneID) ?? .live(terminalID: nil) }
        let args = Self.paneSendTargetQuery(server: server, paneID: paneID)
        do {
            return Self.parsePaneSendTarget(try await runTmux(args), paneID: paneID)
        } catch TmuxError.commandFailed {
            return .missing
        }
    }

    /// Stamp `@tbd_terminal_id` onto a freshly created or respawned pane, when
    /// the spawn's environment says which terminal it is.
    ///
    /// Called centrally from `createWindow` and `respawnWindow`, so every spawn
    /// call site is covered by the one rule "whatever you plant as
    /// `TBD_TERMINAL_ID` is what the pane will answer with" — a call site opts
    /// out only by not planting the variable at all, which is a hole in the
    /// send check rather than a local choice. Best-effort: a failed stamp is
    /// logged and swallowed, because `#{pane_start_command}` carries the same
    /// id as a fallback (see `resolvePaneTerminalID`) and a window that spawned
    /// fine must not be reported as failed over a label.
    ///
    /// Deliberately NOT backfilled onto existing panes from the DB at startup.
    /// The DB's pane coordinate is exactly what goes stale when tmux reuses a
    /// pane id, so backfilling would stamp the terminal's identity onto whatever
    /// pane now holds that id — writing the wrong answer into the very check
    /// that exists to catch it. Unstamped panes fall back to their start
    /// command, and panes with neither are treated as unresolvable, never as
    /// disagreeing.
    private func stampTerminalID(
        server: String, target: String, env: [String: String], sensitiveEnv: [String: String]
    ) async {
        guard let terminalID = env["TBD_TERMINAL_ID"] ?? sensitiveEnv["TBD_TERMINAL_ID"] else {
            return
        }
        let args = Self.setPaneTerminalIDCommand(
            server: server, target: target, terminalID: terminalID)
        if dryRun {
            dryRunRecorder?(args)
            return
        }
        do {
            try await runTmux(args)
        } catch {
            logger.warning("""
                stamping \(Self.terminalIDPaneOption, privacy: .public) on \
                \(target, privacy: .public) (server \(server, privacy: .public)) failed: \
                \(String(describing: error), privacy: .public) — sends fall back to \
                #{pane_start_command} for this pane's identity
                """)
        }
    }

    public func panePID(server: String, paneID: String) async throws -> String {
        if dryRun { return "0" }
        let args = Self.panePIDQuery(server: server, paneID: paneID)
        return try await runTmux(args).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The pane's current working directory (`#{pane_current_path}`). Used by
    /// the hibernation wake path to assert the cwd matches the worktree before
    /// a cwd-scoped `claude --resume`.
    public func paneCurrentPath(server: String, paneID: String) async throws -> String {
        if dryRun { return "" }
        let args = Self.paneCurrentPathQuery(server: server, paneID: paneID)
        return try await runTmux(args).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the pane is in copy-mode/scrollback — keystrokes would go
    /// to the mode, not the application (spec §Actuation 4).
    public func paneInMode(server: String, paneID: String) async throws -> Bool {
        if dryRun { return false }
        let args = Self.paneInModeQuery(server: server, paneID: paneID)
        return try await runTmux(args).trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// The tmux server's own process pid (the parent of every pane process),
    /// or nil if the server can't be queried (e.g. no sessions / not running).
    public func serverPID(server: String) async -> Int32? {
        if dryRun { return nil }
        let args = Self.serverPIDQuery(server: server)
        guard let out = try? await runTmux(args) else { return nil }
        return Int32(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Every live pane's `pane_pid` across all sessions on the server.
    public func livePanePIDs(server: String) async -> Set<Int32> {
        if dryRun { return [] }
        let args = Self.listAllPanePIDsCommand(server: server)
        guard let out = try? await runTmux(args) else { return [] }
        var pids: Set<Int32> = []
        for line in out.split(separator: "\n") {
            if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) { pids.insert(pid) }
        }
        return pids
    }

    public func sendCommand(server: String, paneID: String, command: String) async throws {
        let args = Self.sendCommandArgs(server: server, paneID: paneID, command: command)
        if dryRun {
            dryRunRecorder?(args)
            return
        }
        try await runTmux(args)
    }

    public func listWindows(server: String, session: String) async throws -> [(windowID: String, paneID: String)] {
        if dryRun { return dryRunListWindows?(server, session) ?? [] }
        let args = Self.listWindowsCommand(server: server, session: session)
        let output = try await runTmux(args)
        return output
            .split(separator: "\n")
            .compactMap { line -> (windowID: String, paneID: String)? in
                let parts = line.split(separator: " ")
                guard parts.count == 2 else { return nil }
                return (windowID: String(parts[0]), paneID: String(parts[1]))
            }
    }

    /// Every session on a server, with how many clients are attached to each.
    ///
    /// Throws when the server is not running (`list-sessions` fails), which is
    /// what callers want: "no server" is not the same answer as "no sessions",
    /// and a caller reclaiming sessions must not read a wedged server as an
    /// empty one.
    public func listSessions(server: String) async throws -> [(name: String, attachedClients: Int)] {
        if dryRun { return dryRunListSessions?(server) ?? [] }
        let args = Self.listSessionsCommand(server: server)
        let output = try await runTmux(args)
        return output
            .split(separator: "\n")
            .compactMap { line -> (name: String, attachedClients: Int)? in
                // Split once: everything past the first space is the name.
                guard let separator = line.firstIndex(of: " ") else { return nil }
                guard let attached = Int(line[line.startIndex..<separator]) else { return nil }
                let name = String(line[line.index(after: separator)...])
                guard !name.isEmpty else { return nil }
                return (name: name, attachedClients: attached)
            }
    }

    /// Kill one session by name. The windows it holds survive when they are
    /// linked from another session — which is exactly the case for the
    /// external-attach sessions the reconciler reclaims: their single window
    /// is `link-window`ed from `main`.
    public func killSession(server: String, session: String) async throws {
        let args = Self.killSessionCommand(server: server, session: session)
        if dryRun {
            dryRunRecorder?(args)
            return
        }
        try await runTmux(args)
    }

    /// Check whether a tmux window exists by querying list-panes.
    public func windowExists(server: String, windowID: String) async -> Bool {
        if dryRun { return !(dryRunWindowIsDead?(windowID) ?? false) }
        if let override = realModeWindowExistsOverride?(server, windowID) {
            return override
        }
        do {
            let args = ["-L", server, "list-panes", "-t", windowID]
            _ = try await runTmux(args)
            return true
        } catch {
            return false
        }
    }

    /// Check whether a tmux server is running by querying list-sessions.
    public func serverExists(server: String) async -> Bool {
        if dryRun { return true }
        do {
            let args = ["-L", server, "list-sessions"]
            _ = try await runTmux(args)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private

    /// Resolves tmux from the daemon's inherited PATH, then the saved executable fallback.
    static func tmuxPath(
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        configurationURL: URL? = nil
    ) -> String? {
        var environment = ProcessInfo.processInfo.environment
        if let path {
            environment["PATH"] = path
        } else {
            environment.removeValue(forKey: "PATH")
        }
        return TmuxExecutableResolver(
            environment: environment,
            configurationURL: configurationURL
        ).resolve()?.path
    }

    @discardableResult
    private func runTmux(_ arguments: [String]) async throws -> String {
        guard let executable = Self.tmuxPath() else {
            throw TmuxError.commandFailed(
                command: "tmux " + arguments.joined(separator: " "),
                status: 127,
                output: "tmux executable is unavailable"
            )
        }
        return try await Self.runExternalCommand(
            executable: executable,
            arguments: arguments,
            label: "tmux",
            timeout: subprocessTimeout
        )
    }

    /// Runs an external command with a hard timeout, draining stdout/stderr.
    /// On timeout the child is signalled SIGTERM, then SIGKILL after a short
    /// grace, and the call throws `TmuxError.timedOut` — never hangs. All the
    /// mechanism (starvation-proof watchdog thread, authoritative deadline,
    /// incremental pipe draining, no-EOF-wait, single-resume guard) lives in
    /// the shared `runBoundedProcess`; this only maps the outcome to `TmuxError`.
    ///
    /// Package-internal (not `private`) so timeout tests can drive it directly
    /// against a real slow binary (`/bin/sleep`) without a tmux server.
    ///
    /// `clock` is contract 1's shape applied to a static function rather than an
    /// initializer (last parameter, named `clock`, defaulted, existential): it
    /// arms the deadline a second time so tests can drive it in virtual time.
    /// See `runBoundedProcess` for why the watchdog stays alongside it.
    @discardableResult
    static func runExternalCommand(
        executable: String,
        arguments: [String],
        label: String,
        timeout: Duration,
        clock: any Clock<Duration> = ContinuousClock()
    ) async throws -> String {
        let commandDescription = "\(label) " + arguments.joined(separator: " ")
        switch try await runBoundedProcess(
            executable: executable,
            arguments: arguments,
            currentDirectory: nil,
            timeout: timeout,
            clock: clock
        ) {
        case .timedOut:
            logger.warning("subprocess timed out after \(timeout, privacy: .public): \(commandDescription, privacy: .public)")
            throw TmuxError.timedOut(command: commandDescription, timeout: timeout)
        case let .completed(status, stdoutData, stderrData):
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            let output = stdout.isEmpty ? stderr : stdout
            if status != 0 {
                throw TmuxError.commandFailed(command: commandDescription, status: status, output: output)
            }
            return stdout
        }
    }
}

/// One-shot claim used to enforce the single-resume contract of a
/// `CheckedContinuation` shared across a termination handler, a timeout timer,
/// and a spawn-failure path. `claim()` returns `true` exactly once.
/// Package-internal so the git runner reuses it for the same purpose.
final class ContinuationGuard: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    /// Returns true the first time it is called, false thereafter.
    func claim() -> Bool {
        lock.withLock { resumed in
            if resumed { return false }
            resumed = true
            return true
        }
    }

    /// Whether the continuation has already been resumed by someone. Read by the
    /// spawn path to detect a deadline that fired *during* `Process.run()`.
    var isClaimed: Bool { lock.withLock { $0 } }
}

/// Failure of a tmux subcommand.
///
/// Conforms to `LocalizedError` so `localizedDescription` renders a sentence
/// naming the subcommand, its exit status and tmux's own output. Without it the
/// `NSError` bridge prints "TBDDaemonLib.TmuxError error 0", which names the
/// type and the case index and nothing else — every daemon log line that formats
/// a caught error through `localizedDescription` would throw the payload away.
public enum TmuxError: Error, Sendable, CustomStringConvertible, LocalizedError {
    case commandFailed(command: String, status: Int32, output: String)
    case unexpectedOutput(String)
    /// The subprocess outlived its timeout and was killed. Callers on the wake
    /// path catch this and leave the row hibernated for retry rather than
    /// hanging until the app's 300s RPC ceiling.
    case timedOut(command: String, timeout: Duration)

    public var description: String {
        switch self {
        case let .commandFailed(command, status, output):
            let detail = Self.truncate(output)
            let suffix = detail.isEmpty ? "" : "\nOutput: \(detail)"
            return "tmux command failed (exit \(status)): \(command)\(suffix)"
        case let .unexpectedOutput(output):
            let detail = Self.truncate(output)
            return "tmux returned unexpected output: \(detail.isEmpty ? "(none)" : detail)"
        case let .timedOut(command, timeout):
            return "tmux command timed out after \(timeout): \(command)"
        }
    }

    public var errorDescription: String? { description }

    /// Bounds tmux's own output at ~500 characters so a wall of stderr can't
    /// swamp the log line — long enough for the messages tmux actually emits
    /// ("no server running on …", "can't find window", a failed shell command)
    /// and short enough to stay one readable record.
    static func truncate(_ text: String, maxLength: Int = 500) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength))
            .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
