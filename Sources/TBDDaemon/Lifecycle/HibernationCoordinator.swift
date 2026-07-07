import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "Hibernation")

public enum HibernateResult: Equatable, Sendable {
    case ok
    case alreadyHibernated
    case notEligible(reason: String)
    case notFound
}

public enum WakeResult: Equatable, Sendable {
    case ok
    case notHibernated   // idempotent no-op: nothing to wake
    case notFound        // terminal/worktree DB row missing — NOT tmux failures
    case noSessionID
    case inFlight        // a wake for this terminal is already respawning
    /// The respawn (or window recreate) failed in tmux. The row stays parked
    /// so a later retry can wake it; `reason` names the real failure instead
    /// of the misleading "Terminal not found".
    case respawnFailed(reason: String)
}

/// Owns session PARKING — the single unified "park a Claude session" feature
/// (the former Suspend and Hibernate features merged into one). It gracefully
/// terminates a Claude process while KEEPING its tmux window alive (the shell
/// stays), and wakes it later by respawning `claude --resume <id>` in that same
/// window.
///
/// The park sequence combines the strengths of both predecessors:
///   1. Capture an ANSI pane snapshot FIRST (from the old Suspend feature) so
///      the app can show the frozen pane as a backdrop while parked / waking.
///   2. Enforce the live rails the DB row can't express (typed-but-unsent
///      input, transcript-tail validity) — from Hibernate.
///   3. Try a polite in-band `/exit` (from Suspend) so Claude flushes its
///      transcript, shuts down MCP children, and fires Stop hooks; poll up to
///      ~3s for the process to actually leave.
///   4. If `/exit` didn't take, fall back to a graceful interrupt
///      (Escape → C-c C-c → SIGTERM) — from Hibernate.
///   5. Either way, `respawn-window` the pane to a bare shell (Hibernate's
///      mechanic: the window/pane and its scrollback survive, freeing the
///      claude process + its RSS). We do NOT kill the window (Suspend's old
///      mechanic).
///   6. Verify the shell survived + log orphaned claude children.
///   7. Mark parked via `hibernatedAt` (the authoritative timestamp) and
///      persist the snapshot.
///
/// Wake `respawn-window`s the same pane back to `claude --resume`. It is the ONE
/// resume path for auto-parked, manually-parked, and (via reconcile) died
/// sessions; it clears BOTH `hibernatedAt` and any legacy `suspendedAt`.
///
/// The prompt cache expires after ~5 min idle, so a session past the TTL pays
/// full uncached input on its next message whether or not the process stayed
/// alive — parking an idle session is therefore nearly free.
public actor HibernationCoordinator {
    private let db: TBDDatabase
    private let tmux: TmuxManager
    private let detector: ClaudeStateDetector
    private let modelProfileResolver: ModelProfileResolver?
    private let subscriptions: StateSubscriptionManager?
    private let now: @Sendable () -> Date

    /// Per-terminal "first time we observed it idle-at-rest" marker, maintained
    /// by `sweep`. In-memory only: a daemon restart clears it, so a freshly
    /// started daemon won't instantly hibernate long-idle sessions — it waits a
    /// full idle window first, which is the safe behavior.
    private var idleSince: [UUID: Date] = [:]

    /// Terminal ids with an in-flight wake respawn, so a double-focus can't
    /// spawn two `claude --resume` processes into the same window.
    private var wakesInFlight: Set<UUID> = []

    /// Invoked after EVERY `ensureServer` on the wake-recreate path (whether or
    /// not a server was actually created — the downstream control-mode
    /// `enableIfGated` is idempotent, so firing on an existing server is a
    /// no-op). Daemon.swift wires this to the control-mode bridge so a freshly
    /// recreated server gets the same gated `tmux -CC` connection as every
    /// other `ensureServer()` call site.
    private var onServerCreated: (@Sendable (String) async -> Void)?

    /// Terminal ids with an in-flight hibernate, so a manual "Hibernate now"
    /// racing the idle sweep (or two sweeps) can't respawn-to-shell twice.
    private var hibernatesInFlight: Set<UUID> = []

    /// Debounce after a terminal first crosses the idle threshold: the sweep
    /// marks it `pendingKillSince`, and only actually hibernates on a LATER
    /// sweep once this settle window has also elapsed AND every rail still
    /// holds. State can flip in the final instant (a turn starts, a permission
    /// prompt appears), so the kill decision is re-verified here, not at
    /// arm-time. (Knative/KEDA poll-cheaply / decide-against-window pattern.)
    private var pendingKillSince: [UUID: Date] = [:]

    /// Settle window between crossing the idle threshold and the actual kill.
    static let killDebounce: TimeInterval = 20

    /// Verify-exit poll after the polite in-band `/exit`: how many times we
    /// re-check the pane's current command, and how long we wait between checks.
    /// 15 × 200ms ≈ 3s — ported from the old Suspend feature. If claude is still
    /// the pane's program after the whole window, we fall back to SIGTERM.
    static let exitPollAttempts = 15
    static let exitPollInterval: Duration = .milliseconds(200)

    private var defaultShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    public init(
        db: TBDDatabase,
        tmux: TmuxManager,
        modelProfileResolver: ModelProfileResolver? = nil,
        subscriptions: StateSubscriptionManager? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.db = db
        self.tmux = tmux
        self.detector = ClaudeStateDetector(tmux: tmux)
        self.modelProfileResolver = modelProfileResolver
        self.subscriptions = subscriptions
        self.now = now
    }

    /// Wire the post-`ensureServer` hook (see `onServerCreated`). Set once by
    /// Daemon.swift right after construction, mirroring how the RPC router's
    /// `controlMode` is wired post-construction.
    public func setOnServerCreated(_ hook: (@Sendable (String) async -> Void)?) {
        onServerCreated = hook
    }

    // MARK: - Keep-warm

    public func setKeepWarm(terminalID: UUID, keepWarm: Bool) async -> Bool {
        guard let terminal = try? await db.terminals.get(id: terminalID) else { return false }
        try? await db.terminals.setKeepWarm(id: terminalID, keepWarm: keepWarm)
        broadcastHibernation(terminal: terminal, hibernated: terminal.isHibernated, keepWarm: keepWarm)
        return true
    }

    // MARK: - Hibernate

    /// Manual "Hibernate now". Honors the running / permission-prompt rails but
    /// not keep-warm or idle-time (the user asked explicitly).
    public func manualHibernate(terminalID: UUID) async -> HibernateResult {
        guard let terminal = try? await db.terminals.get(id: terminalID) else {
            return .notFound
        }
        guard terminal.hibernatedAt == nil else { return .alreadyHibernated }
        guard terminal.isManuallyHibernatable else {
            return .notEligible(reason: manualBlockReason(terminal))
        }
        return await performHibernate(terminal: terminal)
    }

    /// The reason a manual hibernate was refused, for the RPC error string.
    private func manualBlockReason(_ terminal: Terminal) -> String {
        if !terminal.isClaudeResumable { return "Not a resumable Claude session" }
        if terminal.suspendedAt != nil { return "Terminal is suspended" }
        switch terminal.activityState {
        case .working: return "Session is actively running"
        case .waitingForUser: return "Session is waiting on a permission prompt"
        default: return "Not hibernatable"
        }
    }

    /// Gracefully terminate the pane's Claude and swap the pane to a bare shell
    /// via `respawn-window` (window + tab survive). Marks the row hibernated.
    ///
    /// Singleflighted per-terminal, and re-verifies the live pane/disk rails
    /// (typed-but-unsent input, transcript-tail validity) that the DB row can't
    /// express. After the kill it verifies the claude process is gone and the
    /// pane's shell survived, and logs any orphaned claude children.
    private func performHibernate(terminal: Terminal) async -> HibernateResult {
        guard !hibernatesInFlight.contains(terminal.id) else {
            return .alreadyHibernated
        }
        hibernatesInFlight.insert(terminal.id)
        defer { hibernatesInFlight.remove(terminal.id) }

        guard let sessionID = terminal.claudeSessionID else {
            return .notEligible(reason: "No session id to resume later")
        }
        guard let worktree = try? await db.worktrees.get(id: terminal.worktreeID) else {
            return .notFound
        }
        let server = worktree.tmuxServer
        let paneID = terminal.tmuxPaneID
        let windowID = terminal.tmuxWindowID

        // Capture the ANSI pane snapshot FIRST (ported from the old Suspend
        // feature), before any interrupt disturbs the pane. Doubles as the
        // input for the typed-but-unsent rail below, so we capture once. If
        // capture fails we proceed with no snapshot (the DB rails already
        // cleared it as idle-at-rest); parked-view falls back to a blank pane.
        let capturedSnapshot: String?
        if let capture = try? await tmux.capturePaneWithAnsi(server: server, paneID: paneID) {
            // Rail: typed-but-unsent input. Chrome's single biggest tab-discard
            // backlash was lost typed text — never park a pane with a
            // half-composed prompt.
            if HibernationSafetyChecks.hasPendingInput(paneCapture: capture) {
                logger.debug("hibernate: skipping \(terminal.id, privacy: .public) — pending typed input in prompt")
                return .notEligible(reason: "Terminal has unsent typed input")
            }
            capturedSnapshot = capture.isEmpty ? nil : capture
        } else {
            capturedSnapshot = nil
        }

        // Rail: transcript-tail validity. Killing mid-write can leave an
        // unresumable jsonl (#18880). Only park when the last line is
        // complete JSON. Missing/empty transcript is allowed (nothing to
        // corrupt); the resume will just find no prior turns.
        if let transcriptPath = terminal.transcriptPath,
           let body = try? String(contentsOfFile: transcriptPath, encoding: .utf8),
           !HibernationSafetyChecks.isTranscriptTailValid(jsonlBody: body) {
            logger.warning("hibernate: skipping \(terminal.id, privacy: .public) — transcript tail not parseable, would be unresumable")
            return .notEligible(reason: "Transcript is mid-write; try again shortly")
        }

        // Polite park: try an in-band `/exit` first (ported from Suspend) so
        // Claude flushes its transcript, shuts down MCP children, and fires Stop
        // hooks, then poll up to ~3s for the process to actually leave. Only if
        // it's still a claude process after the poll window do we escalate to
        // the graceful-interrupt SIGTERM fallback. Either way, `respawn-window
        // -k` below guarantees termination.
        let exited = await politeExitThenPoll(server: server, paneID: paneID, terminalID: terminal.id)
        if !exited {
            logger.debug("hibernate: /exit did not terminate \(terminal.id, privacy: .public) within poll window — falling back to graceful interrupt")
            await gracefullyInterruptPane(server: server, paneID: paneID)
        }

        // Respawn the SAME window to a bare login shell: the claude process (and
        // its RSS) is gone, but the tmux window/pane and its scrollback stay.
        do {
            try await tmux.respawnWindow(
                server: server,
                windowID: windowID,
                cwd: worktree.path,
                shellCommand: defaultShell
            )
        } catch {
            logger.warning("hibernate: respawn-to-shell failed for terminal \(terminal.id, privacy: .public) window \(windowID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .notEligible(reason: "Failed to respawn shell")
        }

        // Post-kill verification: the pane must now be running a shell, not
        // claude. respawn-window -k replaces the pane's program, so this
        // confirms the swap took and the shell (window) survived. Any leftover
        // orphaned claude child processes (#43944, #25188) are logged but not
        // killed in v1 — surfacing them is enough.
        await verifyHibernationTookEffect(server: server, paneID: paneID, terminalID: terminal.id)

        do {
            try await db.terminals.setHibernated(
                id: terminal.id, sessionID: sessionID, snapshot: capturedSnapshot, at: now()
            )
        } catch {
            logger.warning("hibernate: failed to mark hibernated for \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        // Hibernation = parking; a parked pane must not receive a scheduled
        // auto-resume send (spec §Cancellation); fire-time eligibility
        // re-checks are the backstop.
        _ = try? await db.scheduledResumes.cancelPending(terminalID: terminal.id)
        idleSince[terminal.id] = nil
        pendingKillSince[terminal.id] = nil
        broadcastHibernation(terminal: terminal, hibernated: true, keepWarm: terminal.keepWarm)
        logger.info("hibernated terminal \(terminal.id, privacy: .public) (session \(sessionID, privacy: .public))")
        return .ok
    }

    /// Confirm the respawn-to-shell actually replaced claude, and log any
    /// orphaned claude children left behind. Best-effort, log-only.
    private func verifyHibernationTookEffect(server: String, paneID: String, terminalID: UUID) async {
        if let cmd = try? await tmux.paneCurrentCommand(server: server, paneID: paneID),
           ClaudeStateDetector.isClaudeProcess(cmd) {
            logger.warning("hibernate: pane for terminal \(terminalID, privacy: .public) still shows claude after respawn (\(cmd, privacy: .public))")
        }
        // Detect orphaned claude descendants (children reparented to launchd
        // after the parent died) so they're observable via `log stream`.
        if let orphans = await Self.detectOrphanedClaudeProcesses(), !orphans.isEmpty {
            logger.warning("hibernate: \(orphans.count, privacy: .public) orphaned claude-descendant process(es) survived hibernation of terminal \(terminalID, privacy: .public): PIDs \(orphans.map(String.init).joined(separator: ","), privacy: .public)")
        }
    }

    /// Enumerate claude processes now parented to PID 1 (launchd) — a rough
    /// signal of orphaned children left by a killed claude. Log-only in v1.
    ///
    /// Runs through the shared bounded runner (`TmuxManager.runExternalCommand`)
    /// which drains stdout concurrently with the child. The naive
    /// `waitUntilExit()`-then-read shape deadlocked forever once `ps -Ao`
    /// output exceeded the 64KB kernel pipe buffer (~900+ processes), hanging
    /// every hibernation. This is a best-effort diagnostic: any failure —
    /// including timeout — returns nil and must never block hibernation.
    ///
    /// Package-internal + parameterized so tests can substitute a fake `ps`
    /// that deterministically emits more than 64KB.
    static func detectOrphanedClaudeProcesses(
        psExecutable: String = "/bin/ps",
        arguments: [String] = ["-Ao", "pid=,ppid=,comm="],
        timeout: Duration = .seconds(5)
    ) async -> [Int]? {
        guard let out = try? await TmuxManager.runExternalCommand(
            executable: psExecutable,
            arguments: arguments,
            label: "ps",
            timeout: timeout
        ) else { return nil }
        var orphans: [Int] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int(parts[0]), let ppid = Int(parts[1]) else { continue }
            let comm = parts[2...].joined(separator: " ")
            if ppid == 1 && comm.contains("claude") { orphans.append(pid) }
        }
        return orphans
    }

    // MARK: - Wake

    /// Respawn `claude --resume <sessionID>` in the hibernated terminal's
    /// kept-alive window. Idempotent: a non-hibernated terminal is a no-op, and
    /// concurrent wakes for the same terminal collapse to one respawn.
    ///
    /// If the window is GONE (killed, or the whole tmux server died — e.g. a
    /// machine reboot), the window is recreated (ensureServer + createWindow)
    /// and the same resume command spawned there; the terminal row keeps its
    /// identity and gets the new window/pane ids persisted.
    public func wake(terminalID: UUID, cols: Int? = nil, rows: Int? = nil) async -> WakeResult {
        guard let terminal = try? await db.terminals.get(id: terminalID) else {
            return .notFound
        }
        // Wake ANY parked row, not just `hibernatedAt`-marked ones: legacy rows
        // and the reconcile / recreate-window paths may carry only `suspendedAt`.
        // `clearHibernated` nils both columns, so this fully un-parks either.
        guard terminal.isParked else { return .notHibernated }
        guard let sessionID = terminal.claudeSessionID else { return .noSessionID }
        guard !wakesInFlight.contains(terminalID) else { return .inFlight }
        guard let worktree = try? await db.worktrees.get(id: terminal.worktreeID) else {
            return .notFound
        }

        wakesInFlight.insert(terminalID)
        defer { wakesInFlight.remove(terminalID) }

        let server = worktree.tmuxServer
        let paneID = terminal.tmuxPaneID
        let windowID = terminal.tmuxWindowID

        // `claude --resume` is cwd-scoped (session lookup is per-directory).
        // Respawning inside the existing window already runs in the worktree,
        // but assert it so a moved/relocated worktree can't silently resume in
        // the wrong directory (or fail to find the session).
        if let paneCwd = try? await tmux.paneCurrentPath(server: server, paneID: paneID),
           paneCwd != worktree.path {
            logger.warning("wake: pane cwd \(paneCwd, privacy: .public) != worktree path \(worktree.path, privacy: .public) for terminal \(terminal.id, privacy: .public); respawn will -c into the worktree path")
        }

        // Honor the exact profile persisted on the terminal (loadByID, not
        // re-resolve) so wake lands on the same account the session used.
        var resolvedProfile: ResolvedModelProfile? = nil
        if let profileID = terminal.profileID, let resolver = modelProfileResolver {
            resolvedProfile = try? await resolver.loadByID(profileID)
            if resolvedProfile == nil {
                logger.warning("wake: profile \(profileID, privacy: .public) missing for terminal \(terminal.id, privacy: .public); falling back to keychain login")
            }
        }

        let config = try? await db.config.get()
        let claudeEnvOverrides = config?.envSettingOverrides ?? [:]
        let repo: Repo?
        if let rid = worktree.repoID {
            repo = try? await db.repos.get(id: rid)
        } else {
            repo = nil
        }
        let mergedEnvOverrides = EnvOverrideResolver.merge(
            global: config?.envOverrides,
            repo: repo?.envOverrides,
            profile: resolvedProfile?.envOverrides
        )
        let overlayPath = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: resolvedProfile?.fallbackModels,
            sessionKey: terminal.id.uuidString
        )
        let spawn = ClaudeSpawnCommandBuilder.build(
            resumeID: sessionID,
            freshSessionID: nil,
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: resolvedProfile?.secret,
            profileKind: resolvedProfile?.kind,
            profileBaseURL: resolvedProfile?.baseURL,
            profileModel: resolvedProfile?.model,
            profileAwsRegion: resolvedProfile?.awsRegion,
            profileAwsProfile: resolvedProfile?.awsProfile,
            profileConfigDir: ClaudeProfileConfigDirManager.resolveConfigDir(for: resolvedProfile),
            cmd: nil,
            shellFallback: defaultShell,
            settingsOverlayPath: overlayPath,
            pluginDirPath: PluginDirWriter.pluginDirPath,
            envSettingOverrides: claudeEnvOverrides
        )
        // Inject TBD_WORKTREE_ID + TBD_TERMINAL_ID so notifications and the
        // SessionStart hook attribute to this terminal after the resume rollover.
        let env: [String: String] = [
            "TBD_WORKTREE_ID": worktree.id.uuidString,
            "TBD_TERMINAL_ID": terminal.id.uuidString,
        ]
        let sensitiveEnv = mergedEnvOverrides.merging(spawn.sensitiveEnv) { _, builder in builder }

        // The window/pane the rest of wake must reference: the original ones
        // when the window survived, or the recreated window's fresh ones.
        let livePaneID: String
        let liveWindowID: String

        // Post-reboot a fresh tmux server reissues window ids from @1 again,
        // so a stale parked row's window id can equal a window that ANOTHER
        // terminal's wake just created on the same server. `windowExists`
        // alone is therefore not ownership: if any other terminal currently
        // claims this id, ours is necessarily the stale claim (it predates
        // the reboot) and respawning in place would hijack that terminal's
        // live session. Treat the window as gone and recreate instead.
        let claimedByOther = await windowClaimedByAnotherTerminal(
            server: server, windowID: windowID, excluding: terminal.id
        )
        if claimedByOther {
            logger.info("wake: window \(windowID, privacy: .public) on \(server, privacy: .public) is claimed by another terminal — recreating instead of respawning in place for terminal \(terminal.id, privacy: .public)")
        }

        if !claimedByOther, await tmux.windowExists(server: server, windowID: windowID) {
            do {
                try await tmux.respawnWindow(
                    server: server,
                    windowID: windowID,
                    cwd: worktree.path,
                    shellCommand: spawn.command,
                    env: env,
                    sensitiveEnv: sensitiveEnv,
                    cols: cols,
                    rows: rows
                )
                livePaneID = paneID
                liveWindowID = windowID
            } catch {
                // Leave the row hibernated so the next focus/menu retry can wake it.
                logger.warning("wake: respawn-to-claude failed for terminal \(terminal.id, privacy: .public) window \(windowID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return .respawnFailed(reason: "failed to respawn claude in window \(windowID): \(error.localizedDescription)")
            }
        } else {
            // The window is GONE — killed, the whole tmux server died (a
            // machine reboot destroys every server; `windowExists` returns
            // false on any tmux error, covering both), or its id is owned by
            // another terminal (see above). Recreate the window and spawn the
            // same `claude --resume` there: transcripts live on disk, so
            // resume works fine in a fresh window. Mirrors
            // `handleTerminalRecreateWindow`. Tabs are keyed by terminal id,
            // so keeping the same terminal row preserves the tab.
            do {
                let resolvedCols = cols ?? TmuxManager.defaultCols
                let resolvedRows = rows ?? TmuxManager.defaultRows
                let bootstrapWindowID = try await tmux.ensureServer(
                    server: server,
                    session: "main",
                    cwd: worktree.path,
                    cols: resolvedCols,
                    rows: resolvedRows
                )
                await onServerCreated?(server)
                let window = try await tmux.createWindow(
                    server: server,
                    session: "main",
                    cwd: worktree.path,
                    shellCommand: spawn.command,
                    env: env,
                    sensitiveEnv: sensitiveEnv,
                    cols: resolvedCols,
                    rows: resolvedRows
                )
                // Clean up the old window if it somehow still exists (a
                // transient windowExists misclassification must not leak a
                // live window; usually it's already dead so this no-ops).
                // Skip when another terminal owns the id — killing it would
                // tear down THEIR live window. This must happen AFTER
                // createWindow: if the row ever held the session's only
                // remaining window (e.g. the bootstrap window id), killing
                // it first would destroy the session and make createWindow
                // fail on every retry; killing after the new window exists
                // can never leave the session windowless.
                if !claimedByOther {
                    try? await tmux.killWindow(server: server, windowID: windowID)
                }
                // ensureServer returns the untracked bootstrap window id when
                // it just created the server; kill it now that the real
                // window exists (mirrors WorktreeLifecycle+PreSession).
                if let bootstrapWindowID, !bootstrapWindowID.isEmpty {
                    try? await tmux.killWindow(server: server, windowID: bootstrapWindowID)
                }
                do {
                    try await db.terminals.updateTmuxIDs(
                        id: terminal.id, windowID: window.windowID, paneID: window.paneID
                    )
                } catch {
                    // Don't leave an orphaned claude the DB doesn't know
                    // about: best-effort kill of the just-created window,
                    // and a reason that names the REAL failure (the window
                    // was created fine; persisting the ids failed).
                    try? await tmux.killWindow(server: server, windowID: window.windowID)
                    logger.warning("wake: created window \(window.windowID, privacy: .public) but failed to persist tmux ids for terminal \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return .respawnFailed(reason: "recreated tmux window \(window.windowID), but persisting the new tmux ids failed: \(error.localizedDescription)")
                }
                livePaneID = window.paneID
                liveWindowID = window.windowID
                logger.info("wake: window \(windowID, privacy: .public) was gone for terminal \(terminal.id, privacy: .public); recreated as \(window.windowID, privacy: .public) (pane \(window.paneID, privacy: .public))")
            } catch {
                // Leave the row hibernated so the next focus/menu retry can wake it.
                logger.warning("wake: recreate-window failed for terminal \(terminal.id, privacy: .public) (old window \(windowID, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                return .respawnFailed(reason: "tmux window \(windowID) is gone and could not be recreated: \(error.localizedDescription)")
            }
        }

        do {
            try await db.terminals.clearHibernated(id: terminal.id)
        } catch {
            logger.warning("wake: failed to clear hibernated for \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        idleSince[terminal.id] = nil
        // Carry the LIVE window/pane ids on the un-park broadcast so the app
        // updates its cached row before (together with) the hibernated flip —
        // otherwise the terminal view rebuilds keyed on the dead window and
        // its failed attach re-parks the row (wake flap).
        broadcastHibernation(
            terminal: terminal, hibernated: false, keepWarm: terminal.keepWarm,
            tmuxWindowID: liveWindowID, tmuxPaneID: livePaneID
        )

        // `claude --resume <id>` forks into a NEW session file; re-capture the
        // fresh id so subsequent hibernate/wake reference the live session.
        let termID = terminal.id
        Task {
            try? await Task.sleep(for: .seconds(5))
            if let newID = await self.detector.captureSessionID(server: server, paneID: livePaneID) {
                try? await self.db.terminals.updateSessionID(id: termID, sessionID: newID)
            }
        }
        logger.info("woke terminal \(terminal.id, privacy: .public) (resume \(sessionID, privacy: .public))")
        return .ok
    }

    // MARK: - Idle sweep (auto-hibernate)

    /// One pass of the auto-hibernate idle timer, run cheaply on a short cadence
    /// (poll) while the actual kill decision is made against the 30-min idle
    /// window (decide) — the Knative/KEDA poll/decide split.
    ///
    /// For every Claude terminal:
    ///  - track when it first went idle-at-rest (`idleSince`). Terminals that
    ///    leave the idle state (start working, raise a permission hand, get
    ///    suspended/hibernated) have their marker cleared so the clock restarts
    ///    next time they settle. The daemon's own pane status-polling does NOT
    ///    reset this — the marker keys off the DB activity state, not output
    ///    silence, so a busy-but-silent long tool call correctly stays BUSY and
    ///    an idle session isn't kept awake by our health checks (the bug that
    ///    silently disables Jupyter's idle-culler).
    ///  - once past the idle timeout, arm a short debounce (`pendingKillSince`)
    ///    and only hibernate on a LATER sweep after the debounce also elapses,
    ///    RE-VERIFYING every rail at that moment (state can flip in the final
    ///    instant). `performHibernate` adds the live typed-input / transcript
    ///    rails on top.
    public func sweep() async {
        guard let config = try? await db.config.get() else { return }
        guard let terminals = try? await db.terminals.list() else { return }
        let timeout = TimeInterval(max(1, config.hibernateIdleMinutes)) * 60
        let reference = now()

        // Prune markers for terminals that vanished.
        let liveIDs = Set(terminals.map { $0.id })
        idleSince = idleSince.filter { liveIDs.contains($0.key) }
        pendingKillSince = pendingKillSince.filter { liveIDs.contains($0.key) }

        for terminal in terminals {
            let decision = HibernationGate.decide(
                terminal: terminal,
                autoHibernateEnabled: config.autoHibernateEnabled,
                idleTimeout: timeout,
                idleSince: idleSince[terminal.id],
                now: reference
            )

            switch decision {
            case .eligible:
                // Crossed the idle threshold. Arm the debounce on first
                // sighting; only kill once the settle window has ALSO passed
                // and the rails still hold (re-checked inside performHibernate,
                // and the gate itself is re-run on the next sweep before we get
                // here). A fresh at-rest terminal seeds idleSince here too.
                if idleSince[terminal.id] == nil {
                    // Should be non-nil to reach .eligible, but guard anyway.
                    idleSince[terminal.id] = reference
                }
                if let pending = pendingKillSince[terminal.id] {
                    if reference.timeIntervalSince(pending) >= Self.killDebounce {
                        _ = await performHibernate(terminal: terminal)
                    }
                } else {
                    pendingKillSince[terminal.id] = reference
                }

            case .notIdleLongEnough:
                // At rest but not past the timeout yet: keep/seed the idle
                // marker, clear any stale pending-kill (shouldn't exist).
                if idleSince[terminal.id] == nil {
                    idleSince[terminal.id] = reference
                }
                pendingKillSince[terminal.id] = nil

            case .featureDisabled, .notClaudeResumable, .alreadyHibernated,
                 .suspended, .keepWarm, .running, .waitingForUser:
                // Not at rest (or ineligible): the idle clock and any armed
                // debounce reset so a later settle starts a fresh full window.
                idleSince[terminal.id] = nil
                pendingKillSince[terminal.id] = nil
            }
        }
    }

    // MARK: - Startup Reconciliation

    /// Clear a stale parked timestamp for any terminal whose Claude process is
    /// actually still alive (e.g. the daemon crashed mid-park before `/exit`
    /// landed, or before `respawn-window` ran). Ported from the old Suspend
    /// feature's `reconcileOnStartup`, generalized to the unified state: it
    /// checks BOTH the authoritative `hibernatedAt` and the legacy `suspendedAt`
    /// so a row parked by either path is reconciled, and `clearHibernated` nils
    /// both. Called once on daemon startup.
    public func reconcileOnStartup() async {
        guard let allTerminals = try? await db.terminals.list() else { return }

        for terminal in allTerminals where terminal.isParked {
            guard let worktree = try? await db.worktrees.get(id: terminal.worktreeID) else { continue }
            let server = worktree.tmuxServer
            let alive = await tmux.windowExists(server: server, windowID: terminal.tmuxWindowID)
            if alive,
               let cmd = try? await tmux.paneCurrentCommand(server: server, paneID: terminal.tmuxPaneID),
               ClaudeStateDetector.isClaudeProcess(cmd) {
                try? await db.terminals.clearHibernated(id: terminal.id)
                logger.info("startup: cleared stale parked state for still-running terminal \(terminal.id, privacy: .public)")
            }
        }
    }

    // MARK: - Helpers

    /// Send an in-band `/exit` (ported from the old Suspend feature) and poll
    /// the pane's current command up to `exitPollAttempts` × `exitPollInterval`
    /// (~3s) for the claude process to leave. Returns `true` if the pane is no
    /// longer running a claude process by the end of the window (polite exit
    /// succeeded), `false` if it's still claude (caller escalates to SIGTERM).
    ///
    /// If we can't even send `/exit`, we return `false` so the caller falls back
    /// — `respawn-window -k` still guarantees the process dies either way.
    private func politeExitThenPoll(server: String, paneID: String, terminalID: UUID) async -> Bool {
        do {
            try await tmux.sendCommand(server: server, paneID: paneID, command: "/exit")
        } catch {
            logger.debug("hibernate: /exit send failed for \(terminalID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
        for _ in 0..<Self.exitPollAttempts {
            try? await Task.sleep(for: Self.exitPollInterval)
            if let cmd = try? await tmux.paneCurrentCommand(server: server, paneID: paneID),
               !ClaudeStateDetector.isClaudeProcess(cmd) {
                return true
            }
        }
        return false
    }

    /// Escape → settle → C-c C-c → settle → SIGTERM. Best-effort; the
    /// subsequent `respawn-window -k` guarantees termination. Copied from the
    /// swap path so hibernate and account-switch interrupt identically.
    private func gracefullyInterruptPane(server: String, paneID: String) async {
        try? await tmux.sendKey(server: server, paneID: paneID, key: "Escape")
        try? await Task.sleep(for: .milliseconds(150))
        try? await tmux.sendKey(server: server, paneID: paneID, key: "C-c")
        try? await tmux.sendKey(server: server, paneID: paneID, key: "C-c")
        try? await Task.sleep(for: .milliseconds(150))
        if let pidStr = try? await tmux.panePID(server: server, paneID: paneID),
           let pid = Int32(pidStr), pid > 0 {
            kill(pid, SIGTERM)
        }
    }

    /// True when any OTHER terminal row whose worktree lives on the same tmux
    /// server currently claims `windowID`. A fresh (post-reboot) server
    /// reissues window ids from @1, so a stale parked row can collide with a
    /// window a different terminal's wake just created — and the other row's
    /// claim is necessarily the fresher one. Worktrees can share a per-repo
    /// server, so ownership is resolved across all worktrees with the same
    /// `tmuxServer` string, not just this terminal's worktree.
    private func windowClaimedByAnotherTerminal(
        server: String, windowID: String, excluding terminalID: UUID
    ) async -> Bool {
        guard let terminals = try? await db.terminals.list(),
              let worktrees = try? await db.worktrees.list() else { return false }
        let serverWorktreeIDs = Set(worktrees.filter { $0.tmuxServer == server }.map(\.id))
        return terminals.contains {
            $0.id != terminalID
                && $0.tmuxWindowID == windowID
                && serverWorktreeIDs.contains($0.worktreeID)
        }
    }

    private func broadcastHibernation(
        terminal: Terminal, hibernated: Bool, keepWarm: Bool,
        tmuxWindowID: String? = nil, tmuxPaneID: String? = nil
    ) {
        subscriptions?.broadcast(delta: .terminalHibernationChanged(TerminalHibernationDelta(
            terminalID: terminal.id,
            worktreeID: terminal.worktreeID,
            hibernated: hibernated,
            keepWarm: keepWarm,
            tmuxWindowID: tmuxWindowID,
            tmuxPaneID: tmuxPaneID
        )))
    }
}
