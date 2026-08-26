import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "TmuxManager")

/// What one read-only `list-panes` consultation says about a pane that a send
/// is aimed at. Read before anything is typed; see `paneSendTargetQuery`.
///
/// The two negative cases are deliberately separate facts, and conflating them
/// was a real defect: a reachable server answering "no such pane" is positive
/// evidence of absence, while a server that could not be reached at all is a
/// failed READ that says nothing about the pane. The daemon spawns tmux with
/// `environment: nil`, so its `TMUX_TMPDIR` can differ from the user's shell
/// and `-L <name>` can resolve to a different socket file — the second case
/// happens in the field, and reporting it as absence refuses sends to (and,
/// worse, parks) perfectly live sessions. Affirmative evidence of absence is
/// what `docs/specs/2026-08-11-bounded-terminal-recovery-design.md` requires;
/// the app layer already honours it (`TmuxPreparationFailure.windowMissing`
/// versus `.commandFailed`).
public enum PaneSendTarget: Sendable, Equatable {
    /// tmux answered about a reachable server and this pane is not on it — it,
    /// or its window, is gone. Positive evidence of absence.
    case absent
    /// The consultation could not be completed: the server did not answer on
    /// the socket this daemon resolved. NOT evidence about the pane, and never
    /// to be reported as "gone" — the pane may well be alive and typed into by
    /// a shell that resolves the same `-L` name to a different socket.
    case unreachable
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

/// What one read-only consultation says about a tmux resource a caller is
/// about to act on: a window, or a whole server.
///
/// The same three-way split as `PaneSendTarget`, and for the same reason. A
/// `Bool` probe has to spend its one bit on "yes" and then fold both "tmux
/// answered: not here" and "tmux was never reached" into "no" — which is the
/// conflation `docs/specs/2026-08-11-bounded-terminal-recovery-design.md`
/// forbids, because every destructive rail in the daemon (park, delete, kill,
/// respawn, spawn-a-replacement, revoke-a-lease, cancel-a-resume) is gated on
/// that single bit. Making the third case a separate value is what forces each
/// of those rails to decide, at the compiler's insistence, what a FAILED READ
/// means for it — and the answer is always "decline and let a later pass ask
/// again".
public enum TmuxResourcePresence: Sendable, Equatable {
    /// tmux answered and the resource is there.
    case present
    /// tmux answered on a reachable server and the resource is NOT there.
    /// Positive evidence of absence — the only verdict that may license a
    /// destructive or irreversible action.
    case absent
    /// The consultation could not be completed, so nothing is known about the
    /// resource. Never to be reported or treated as absence.
    case unreachable
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
    /// Optional test hook consulted by `windowPresence` in dryRun mode: return
    /// `true` for a window ID to simulate that window having been killed.
    /// Without it, dryRun reports every window as alive, which makes paths
    /// like the pre-session `.paneKilled` short-circuit untestable.
    ///
    /// Two-state by construction, so it can only say `.present` or `.absent`:
    /// `true` means tmux ANSWERED that the window is gone. A fixture that needs
    /// the third fact — the read itself failed — uses `dryRunWindowPresence`,
    /// which takes precedence over this hook when both are set.
    public let dryRunWindowIsDead: (@Sendable (String) -> Bool)?
    /// Optional test hook consulted by `windowPresence` in dryRun mode:
    /// `(server, windowID)` → the full three-way verdict. Consulted before
    /// `dryRunWindowIsDead`, which stays as the two-state shorthand the
    /// existing fixtures are written against.
    ///
    /// This exists because a two-state hook cannot express `.unreachable`, and
    /// `.unreachable` is precisely the state every destructive rail must be
    /// tested against: a fixture that can only say "alive" or "gone" leaves the
    /// failed-read branch — the one that must NOT park, delete, kill, respawn
    /// or revoke — with no way to be exercised, which is how the daemon shipped
    /// a `catch { return false }` in front of the very check that was meant to
    /// stop it.
    public let dryRunWindowPresence: (@Sendable (String, String) -> TmuxResourcePresence)?
    /// Optional test hook consulted by `serverPresence` in dryRun mode:
    /// `server` → the three-way verdict. Without it, dryRun reports every
    /// server `.present`, which is what every pre-existing fixture assumes.
    public let dryRunServerPresence: (@Sendable (String) -> TmuxResourcePresence)?
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
    /// leave that branch with no way to be exercised. Returning `.unreachable`
    /// is the neighbouring case — the consultation ran and could not reach the
    /// server — and every consumer must treat it as "I don't know", never as
    /// "gone".
    public let dryRunPaneSendTarget: (@Sendable (String, String) throws -> PaneSendTarget)?
    /// Optional test hook consulted by `pasteText` in dryRun mode:
    /// `(server, paneID, bytes)` — the payload that would have been written to
    /// the buffer file. `dryRunRecorder` cannot carry it: the real path passes
    /// the body through a temp FILE, so the recorded argv holds a path and not
    /// one byte of the content. Tests that assert on WHAT was pasted — the
    /// dispatch envelope, for one — need the bytes themselves.
    public let dryRunPasteBytes: (@Sendable (String, String, Data) -> Void)?
    /// Optional test hook for real (non-dryRun) mode: override the result of
    /// `windowPresence(server:windowID:)`. Allows tests to force a window as
    /// positively absent while still having a live process running in the pane
    /// (for testing the safety check in reconcile), or to force the failed-read
    /// verdict against a real server.
    public let realModeWindowPresenceOverride: (@Sendable (String, String) -> TmuxResourcePresence?)?
    /// Optional test hook for real (non-dryRun) mode: override the result of
    /// `paneCurrentCommand(server:paneID:)`. Allows tests to return a specific
    /// command string without relying on tmux's actual pane_current_command.
    public let realModePaneCurrentCommandOverride: (@Sendable (String, String) -> String?)?
    /// Seam for the out-of-tmux evidence `serverPresence` consults after a
    /// `list-sessions` that did not answer: does ANY tmux server process exist
    /// for this uid?
    ///
    /// Two nils, deliberately, and they mean different things:
    /// - the **property** being nil ⇒ use the production `/bin/ps` probe.
    /// - the closure **returning** nil ⇒ the probe itself could not be taken,
    ///   which is never evidence of absence (see `serverPresence`).
    ///
    /// Consulted in real mode only; dryRun answers from `dryRunServerPresence`
    /// long before this is reached. It exists because the condition that makes
    /// the probe interesting — a machine with no tmux process running anywhere
    /// — is not something a test on a shared developer box or a CI runner can
    /// arrange, and certainly not one that starts real tmux servers of its own.
    public let tmuxServerProcessProbe: (@Sendable () async -> Bool?)?

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

    public init(dryRun: Bool = false, dryRunRecorder: (@Sendable ([String]) -> Void)? = nil, dryRunWindowIsDead: (@Sendable (String) -> Bool)? = nil, dryRunWindowPresence: (@Sendable (String, String) -> TmuxResourcePresence)? = nil, dryRunServerPresence: (@Sendable (String) -> TmuxResourcePresence)? = nil, dryRunListWindows: (@Sendable (String, String) -> [(windowID: String, paneID: String)])? = nil, dryRunCapturePane: (@Sendable (String, String) -> String)? = nil, dryRunPaneCurrentCommand: (@Sendable (String, String) -> String)? = nil, dryRunCreateWindowError: (@Sendable (String) -> Error?)? = nil, dryRunRespawnWindowError: (@Sendable (String) -> Error?)? = nil, dryRunKillWindowError: (@Sendable (String, String) -> Error?)? = nil, dryRunPaneSendTarget: (@Sendable (String, String) throws -> PaneSendTarget)? = nil, dryRunPasteBytes: (@Sendable (String, String, Data) -> Void)? = nil, realModeWindowPresenceOverride: (@Sendable (String, String) -> TmuxResourcePresence?)? = nil, realModePaneCurrentCommandOverride: (@Sendable (String, String) -> String?)? = nil, tmuxServerProcessProbe: (@Sendable () async -> Bool?)? = nil, subprocessTimeout: Duration = TmuxManager.commandTimeout) {
        self.dryRun = dryRun
        self.subprocessTimeout = subprocessTimeout
        self.counter = Counter()
        self.resourceCoordinator = TmuxServerResourceCoordinator()
        self.dryRunRecorder = dryRunRecorder
        self.dryRunWindowIsDead = dryRunWindowIsDead
        self.dryRunWindowPresence = dryRunWindowPresence
        self.dryRunServerPresence = dryRunServerPresence
        self.dryRunListWindows = dryRunListWindows
        self.dryRunCapturePane = dryRunCapturePane
        self.dryRunPaneCurrentCommand = dryRunPaneCurrentCommand
        self.dryRunCreateWindowError = dryRunCreateWindowError
        self.dryRunRespawnWindowError = dryRunRespawnWindowError
        self.dryRunKillWindowError = dryRunKillWindowError
        self.dryRunPaneSendTarget = dryRunPaneSendTarget
        self.dryRunPasteBytes = dryRunPasteBytes
        self.realModeWindowPresenceOverride = realModeWindowPresenceOverride
        self.realModePaneCurrentCommandOverride = realModePaneCurrentCommandOverride
        self.tmuxServerProcessProbe = tmuxServerProcessProbe
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

    /// The reachability probe run after a failed `paneSendTargetQuery`: one
    /// read-only, server-wide inventory of pane identities.
    ///
    /// Server-wide (`-a`) rather than `-t <pane>` deliberately. The whole point
    /// is to separate "tmux answered" from "tmux could not be reached", and a
    /// second target-scoped query would fail for BOTH reasons exactly as the
    /// first one did. `list-panes -a` names no target, so its exit status is
    /// about the SERVER: it exits 0 with the inventory when the server answers
    /// and non-zero when nothing is listening on that socket.
    ///
    /// It reports `#{pane_id}` and nothing else — no prose, no stderr parsing.
    /// The bounded-recovery spec rejects reading tmux's human-facing text
    /// ("rendered and human-facing text is not a stable machine interface. Exit
    /// status and formatted identity inventories are"), so absence is concluded
    /// from a formatted inventory that does not contain the id, never from an
    /// error message that says so.
    public static func allPaneIDsQuery(server: String) -> [String] {
        ["-L", server, "list-panes", "-a", "-F", "#{pane_id}"]
    }

    /// The reachability probe run after a failed window consultation: one
    /// read-only, server-wide inventory of window identities.
    ///
    /// The window-space twin of `allPaneIDsQuery`, and server-wide (`-a`) for
    /// the identical reason: naming no target makes its exit status a fact
    /// about the SERVER rather than about the window that just failed, which is
    /// the only way to tell "tmux answered" from "tmux was never reached". It
    /// reports `#{window_id}` and nothing else — an identity inventory, never
    /// tmux's error prose.
    public static func allWindowIDsQuery(server: String) -> [String] {
        ["-L", server, "list-windows", "-a", "-F", "#{window_id}"]
    }

    /// Whether a server-wide `-F` identity inventory names `id`. One line per
    /// resource, so membership is an exact match on the trimmed line.
    static func inventoryLists(_ output: String, id: String) -> Bool {
        output.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces) == id
        }
    }

    /// Whether a server-wide `allPaneIDsQuery` inventory names `paneID`.
    static func paneInventoryLists(_ output: String, paneID: String) -> Bool {
        inventoryLists(output, id: paneID)
    }

    /// Turn a failed window consultation into a verdict, given what the
    /// window-inventory reachability probe saw. Pure, so all three branches are
    /// unit-testable without a tmux server.
    ///
    /// - Parameter windowInventory: `allWindowIDsQuery`'s stdout, or `nil` when
    ///   the probe itself failed.
    ///
    /// The same three cases as `classifyFailedConsultation`, in the window's
    /// identity space:
    /// - probe failed → `.unreachable`. Two failed reads still say nothing.
    /// - probe answered and the inventory does NOT name the window → `.absent`.
    /// - probe answered and the inventory DOES name the window → `.unreachable`.
    ///   Never report a window tmux just listed as gone.
    static func classifyFailedWindowConsultation(
        windowInventory: String?, windowID: String
    ) -> TmuxResourcePresence {
        guard let windowInventory else { return .unreachable }
        return inventoryLists(windowInventory, id: windowID) ? .unreachable : .absent
    }

    /// Turn a failed `list-sessions` into a verdict, given what the process
    /// table said about tmux servers. Pure, so all three branches are
    /// unit-testable without a tmux server and without shelling out to `ps`.
    ///
    /// - Parameter tmuxServerProcessesExist: whether the process table holds at
    ///   least one tmux server process for this uid, or `nil` when the probe
    ///   itself could not be taken.
    ///
    /// The distinction tmux cannot draw — "no server is running under this
    /// name" versus "this process resolved a socket the server is not listening
    /// on" — is drawn from OUTSIDE tmux, where it does exist:
    /// - probe failed → `.unreachable`. A failed probe is never evidence of
    ///   absence; two failed reads still say nothing.
    /// - probe answered and NO tmux server process exists → `.absent`. Nothing
    ///   is running, so nothing can be listening on any socket, whatever
    ///   `TMUX_TMPDIR` resolves to for whoever asks. This is the post-reboot
    ///   case, and the reason it must reclaim: otherwise every row on every
    ///   pre-reboot server accumulates forever.
    /// - probe answered and a tmux server process DOES exist → `.unreachable`.
    ///   Something is running and our socket resolution did not reach it, which
    ///   is exactly the field bug, so the rows are protected.
    static func classifyFailedServerConsultation(
        tmuxServerProcessesExist: Bool?
    ) -> TmuxResourcePresence {
        guard let exists = tmuxServerProcessesExist else { return .unreachable }
        return exists ? .unreachable : .absent
    }

    /// Whether a `/bin/ps` snapshot holds a tmux server process for `uid`.
    ///
    /// **The matching rule, and why it is deliberately name-agnostic.** A row
    /// counts when all of these hold:
    /// 1. `entry.uid == uid` — another user's tmux server cannot be ours and
    ///    cannot be reached on our socket directory either.
    /// 2. `entry.ppid != daemonPID` — this daemon's own in-flight `tmux …` CLI
    ///    invocations are excluded. Those are clients, never servers: tmux's
    ///    server `daemon()`s itself away from its spawning process, so a real
    ///    server's ppid is 1 and never the daemon's.
    /// 3. `isTmuxProcessCommand(entry.command)` — argv[0]'s basename is `tmux`,
    ///    or the command carries the rewritten `tmux: …` process title.
    ///
    /// Rule 3 does NOT try to match `-L <our server name>`, and that is the
    /// point rather than an omission. The thing under suspicion here is our own
    /// *name → socket* resolution: the daemon spawns tmux with `environment:
    /// nil`, so the same `-L <name>` can land on a different socket file than
    /// the shell that started the server used. Deciding "is this our server?"
    /// by re-reading the name from argv would assume the very resolution the
    /// probe exists to doubt, and would miss a server that IS ours under a name
    /// we can no longer resolve. The question asked is the weaker, sounder one:
    /// *is any tmux server at all running for this uid?* Only "no" is used, and
    /// only to license `.absent`.
    ///
    /// Rule 3 also does not try to separate servers from clients, because on
    /// macOS it cannot: tmux rewrites its process title to `tmux: server (…)`
    /// only where `setproctitle` is available, so elsewhere a server keeps the
    /// original argv (`tmux -L … new-session …`) and is indistinguishable from
    /// a client by argv alone. Matching both is sound in the direction that
    /// matters — a tmux *client* only exists while attached to a server, so it
    /// is evidence FOR a running server — and every remaining over-match (a
    /// stranger's short-lived `tmux` CLI) can only produce `.unreachable`, the
    /// verdict that protects rows. An under-match, by contrast, would produce a
    /// wrong `.absent` and park or delete live sessions, so the matcher is
    /// broad on purpose.
    static func tmuxServerProcessesExist(
        in snapshot: [ProcessSnapshotEntry], uid: uid_t, daemonPID: Int32
    ) -> Bool {
        snapshot.contains { entry in
            entry.uid == uid
                && entry.ppid != daemonPID
                && isTmuxProcessCommand(entry.command)
        }
    }

    /// Whether one `ps -o command=` line names a tmux process (server or
    /// client). See `tmuxServerProcessesExist` for why both count.
    ///
    /// Two accepted shapes, and nothing else:
    /// - argv[0]'s last path component is exactly `tmux`, so
    ///   `/opt/homebrew/bin/tmux -L x new-session` matches while a path merely
    ///   containing "tmux" (`/Users/x/tmux-notes/bin/editor`) does not — the
    ///   same basename discipline `AgentReaper.isAgentBinary` uses.
    /// - argv[0] begins `tmux:`, the rewritten title (`tmux: server (…)`,
    ///   `tmux: client (…)`).
    ///
    /// This reads the process table, which is a machine interface — not tmux's
    /// stderr prose, which stays forbidden.
    static func isTmuxProcessCommand(_ command: String) -> Bool {
        guard let arg0 = command.split(
            whereSeparator: { $0 == " " || $0 == "\t" }
        ).first else { return false }
        if arg0.hasPrefix("tmux:") { return true }
        let basename = arg0.split(separator: "/").last.map(String.init) ?? String(arg0)
        return basename == "tmux"
    }

    /// The production out-of-tmux probe: one `/bin/ps` snapshot, classified by
    /// `tmuxServerProcessesExist`. `nil` when the snapshot could not be taken.
    ///
    /// Reuses `OrphanProcessCollector.realProcessSnapshot()` rather than adding
    /// a second way to read the process table — it already carries uid, ppid
    /// and full argv, already bounds the subprocess, and already returns `nil`
    /// (never a partial picture) for a timeout, a non-zero exit or non-UTF-8
    /// output, which is precisely the "the probe itself failed" case.
    ///
    /// Only ever reached after a `list-sessions` that did not answer, and
    /// `reconcileTerminalsWhileLocked` caches `serverPresence` per server name,
    /// so a sweep pays at most one `ps` per unanswered server.
    static func probeTmuxServerProcesses() async -> Bool? {
        guard let snapshot = await OrphanProcessCollector.realProcessSnapshot() else {
            return nil
        }
        return tmuxServerProcessesExist(
            in: snapshot, uid: getuid(), daemonPID: getpid())
    }

    /// Turn a failed `paneSendTargetQuery` into a verdict, given what the
    /// reachability probe saw. Pure, so all three branches are unit-testable
    /// without a tmux server.
    ///
    /// - Parameter paneInventory: `allPaneIDsQuery`'s stdout, or `nil` when the
    ///   probe itself failed.
    ///
    /// Three cases, and only one of them is evidence:
    /// - probe failed → `.unreachable`. Two failed reads in a row still say
    ///   nothing about the pane.
    /// - probe answered and the inventory does NOT name the pane → `.absent`.
    ///   The server is reachable and does not have this pane: positive absence.
    /// - probe answered and the inventory DOES name the pane → `.unreachable`.
    ///   The first failure was transient or anomalous, and the one thing this
    ///   function must never do is report a pane tmux just listed as gone.
    static func classifyFailedConsultation(
        paneInventory: String?, paneID: String
    ) -> PaneSendTarget {
        guard let paneInventory else { return .unreachable }
        return paneInventoryLists(paneInventory, paneID: paneID) ? .unreachable : .absent
    }

    /// Classify `paneSendTargetQuery`'s stdout for the pane the send named.
    /// Pure, so the classification is unit-testable without a tmux server.
    ///
    /// Only the line whose `#{pane_id}` is `paneID` counts — the query returns
    /// one line per pane in the target's window. A run with no such line means
    /// tmux answered — exit 0, on a reachable server — about a window that no
    /// longer holds this pane: positive evidence of absence, `.absent`.
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
        // rc 0 but no line for this pane (including no output at all): the
        // server answered, and nothing on it holds the coordinate the send
        // named.
        return .absent
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
    /// which this catch matches.
    ///
    /// A non-zero *exit* is ambiguous and is NOT read as an answer on its own.
    /// This fixed argv can exit non-zero for two unrelated reasons — the pane
    /// could not be resolved on a server that answered, or no server answered on
    /// that socket at all — and only the first is evidence about the pane. The
    /// second is a failed read: the daemon spawns tmux with `environment: nil`,
    /// so a `TMUX_TMPDIR` that differs from the user's shell puts the same
    /// `-L <name>` on a different socket file, and a live pane then wears the
    /// clothes of a vanished one. So a failure is disambiguated by a positive
    /// server-reachability probe (`allPaneIDsQuery`) rather than by reading
    /// tmux's error prose; see `classifyFailedConsultation`.
    /// (`paneSendTargetQuery`'s exact argv is pinned by a unit test, so it
    /// cannot drift into a usage error that would arrive here wearing the same
    /// clothes.)
    public func paneSendTarget(server: String, paneID: String) async throws -> PaneSendTarget {
        if dryRun { return try dryRunPaneSendTarget?(server, paneID) ?? .live(terminalID: nil) }
        let args = Self.paneSendTargetQuery(server: server, paneID: paneID)
        do {
            return Self.parsePaneSendTarget(try await runTmux(args), paneID: paneID)
        } catch TmuxError.commandFailed {
            let inventory = try? await runTmux(Self.allPaneIDsQuery(server: server))
            let verdict = Self.classifyFailedConsultation(
                paneInventory: inventory, paneID: paneID)
            if verdict == .unreachable {
                // The one drift this whole split exists to make diagnosable in
                // the field: which server name, and which pane, could not be
                // consulted — and whether the reachability probe itself
                // answered (transient failure) or not (socket mismatch / dead
                // server).
                let probeOutcome = inventory == nil
                    ? "the reachability probe also failed"
                    : "the reachability probe still lists the pane"
                logger.warning("""
                    paneSendTarget: could not establish whether pane \(paneID, privacy: .public) \
                    exists on server \(server, privacy: .public) — the consultation failed and \
                    \(probeOutcome, privacy: .public); reporting unreachable rather than absent
                    """)
            }
            return verdict
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

    /// What one read-only `list-panes -t <window>` consultation says about a
    /// window: it is there, tmux answered that it is not, or the read failed.
    ///
    /// A failure is disambiguated exactly the way `paneSendTarget` does it — by
    /// a positive, server-wide identity inventory (`allWindowIDsQuery`), never
    /// by reading tmux's error text. `can't find window` and `no server running
    /// on …` are the same exit status and differ only in prose, and prose is
    /// not a machine interface; the inventory's exit status, on the other hand,
    /// is a fact about the server, and its contents are a fact about the
    /// window. So: probe failed → `.unreachable`; probe answered without this
    /// window → `.absent`; probe answered WITH it → `.unreachable`, because a
    /// window tmux just listed must never be reported gone.
    public func windowPresence(server: String, windowID: String) async -> TmuxResourcePresence {
        if dryRun {
            if let hook = dryRunWindowPresence { return hook(server, windowID) }
            return (dryRunWindowIsDead?(windowID) ?? false) ? .absent : .present
        }
        if let override = realModeWindowPresenceOverride?(server, windowID) {
            return override
        }
        do {
            let args = ["-L", server, "list-panes", "-t", windowID]
            _ = try await runTmux(args)
            return .present
        } catch {
            let inventory = try? await runTmux(Self.allWindowIDsQuery(server: server))
            let verdict = Self.classifyFailedWindowConsultation(
                windowInventory: inventory, windowID: windowID)
            if verdict == .unreachable {
                let probeOutcome = inventory == nil
                    ? "the reachability probe also failed"
                    : "the reachability probe still lists the window"
                logger.warning("""
                    windowPresence: could not establish whether window \
                    \(windowID, privacy: .public) exists on server \(server, privacy: .public) — \
                    the consultation failed and \(probeOutcome, privacy: .public); reporting \
                    unreachable rather than absent
                    """)
            }
            return verdict
        }
    }

    /// What one read-only `list-sessions` consultation says about a tmux
    /// server, with the failed half decided from outside tmux.
    ///
    /// tmux itself offers no way to tell "no server is running under this
    /// socket name" from "this process resolved a socket path the server is not
    /// listening on". Both exit 1 from the same command and differ only in the
    /// prose on stderr, which the bounded-recovery spec forbids reading — and
    /// the mismatch is not hypothetical: the daemon spawns tmux with
    /// `environment: nil`, so a `TMUX_TMPDIR` that differs from the shell that
    /// started the server puts the same `-L <name>` on a different socket file.
    /// There is no positive probe inside tmux to fall back on the way
    /// `windowPresence` has one: a server-wide inventory IS this same question,
    /// and the only command that would answer affirmatively (`start-server`)
    /// answers by creating the thing it was asked about.
    ///
    /// The **process table** is where the distinction does exist, so that is
    /// what a failed `list-sessions` consults. If no tmux server process is
    /// running for this uid at all, then nothing is listening on any socket —
    /// no resolution mismatch can hide a server that does not exist — and the
    /// verdict is `.absent`. That is the post-reboot case, and it has to
    /// reclaim: without it every row on every pre-reboot server is parked-proof
    /// and delete-proof forever, accumulating without bound. If tmux processes
    /// DO exist, or if the probe could not be taken at all, the verdict is
    /// `.unreachable` and every destructive rail declines. A failed probe is
    /// never evidence of absence — that is the whole doctrine here.
    ///
    /// See `tmuxServerProcessesExist` for the matching rule and why it is
    /// deliberately name-agnostic.
    public func serverPresence(server: String) async -> TmuxResourcePresence {
        if dryRun { return dryRunServerPresence?(server) ?? .present }
        do {
            let args = ["-L", server, "list-sessions"]
            _ = try await runTmux(args)
            return .present
        } catch {
            let probe: Bool?
            if let injectedProbe = tmuxServerProcessProbe {
                probe = await injectedProbe()
            } else {
                probe = await Self.probeTmuxServerProcesses()
            }
            let verdict = Self.classifyFailedServerConsultation(
                tmuxServerProcessesExist: probe)
            switch verdict {
            case .absent:
                logger.info("""
                    serverPresence: no answer from tmux server \(server, privacy: .public) and \
                    no tmux server process is running for this uid — reporting absent
                    """)
            case .unreachable:
                let reason = probe == nil
                    ? "the process probe itself failed"
                    : "tmux server processes are running for this uid"
                logger.warning("""
                    serverPresence: no answer from tmux server \(server, privacy: .public) but \
                    \(reason, privacy: .public) — reporting unreachable rather than absent, so \
                    nothing is parked or deleted on a read that proved nothing
                    """)
            case .present:
                break
            }
            return verdict
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
