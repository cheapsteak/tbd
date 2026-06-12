import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "worktreeLifecycle")

/// Descriptor for a spawned pre-session hook terminal. Phase 3 (the marker
/// wait + primary terminal spawn) consumes it.
struct PreSessionSpawn: Sendable {
    let terminalID: UUID
    let windowID: String
    let paneID: String
    let markerPath: String
    let hookPath: String
}

/// How a pre-session hook run ended.
enum PreSessionOutcome: Equatable, Sendable {
    /// The hook wrote its exit code to the marker file.
    case completed(exitCode: Int)
    /// The marker never appeared within the timeout.
    case timedOut
    /// The hook's tmux window disappeared before the marker was written
    /// (user killed the pane). Treated as failure.
    case paneKilled
}

/// What `runPreSessionPhase3` does to the worktree row once the primary
/// terminals are spawned. Phase 3 must always flip the status eventually —
/// the row would otherwise be stuck in `.creating` forever.
enum PreSessionCompletionAction: Sendable {
    /// Create path: set status to `.active`.
    case markActive
    /// Revive path: `db.worktrees.revive(id:clearSessions:)` — flips to
    /// `.active`, clears `archivedAt`, and (when `clearSessions` is true)
    /// clears `archivedClaudeSessions`, preserving the legacy revive
    /// semantics around session restoration.
    case revive(clearSessions: Bool)
}

extension WorktreeLifecycle {

    // MARK: - Paths & command construction

    /// Directory holding pre-session completion markers. TBD_HOME-relative so
    /// tests redirect automatically.
    static var preSessionRuntimeDir: String {
        TBDConstants.configDir
            .appendingPathComponent("runtime")
            .appendingPathComponent("presession")
            .path
    }

    /// Marker file the wrapped hook command writes its exit code to.
    static func preSessionMarkerPath(worktreeID: UUID) -> String {
        (preSessionRuntimeDir as NSString)
            .appendingPathComponent(worktreeID.uuidString)
    }

    /// Wraps the hook so its exit code lands in the marker file and the pane
    /// stays alive as a usable shell afterward (same rationale as
    /// `shellWrapped`). Single-quote escaping matches `shellWrapped`.
    static func preSessionCommand(
        hookPath: String, runtimeDir: String, markerPath: String, shell: String
    ) -> String {
        func quoted(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return "\(quoted(hookPath)); __tbd_rc=$?; "
            + "/bin/mkdir -p \(quoted(runtimeDir)); "
            + "/bin/echo $__tbd_rc > \(quoted(markerPath)); "
            + "exec \(shell)"
    }

    // MARK: - Phase 2b: spawn the pre-session terminal

    /// Resolves the `preSession` hook and, if present, creates its terminal as
    /// the FIRST window of the worktree's tmux session. Returns nil when no
    /// hook resolves — callers then spawn the primary terminals directly
    /// (today's behavior, unchanged).
    func spawnPreSessionTerminal(
        worktree: Worktree, repo: Repo,
        worktreePath: String,
        cols: Int? = nil, rows: Int? = nil
    ) async throws -> PreSessionSpawn? {
        guard let hookPath = hooks.resolve(
            event: .preSession,
            repoPath: worktreePath,
            appHookPath: TBDConstants.hookPath(
                repoID: worktree.repoID, eventName: HookEvent.preSession.rawValue
            )
        ) else {
            return nil
        }

        let worktreeID = worktree.id
        let tmuxServer = worktree.tmuxServer
        let resolvedCols = cols ?? TmuxManager.defaultCols
        let resolvedRows = rows ?? TmuxManager.defaultRows

        // Ensure tmux server exists — capture initial window ID to kill once
        // the first real window (the pre-session one) exists.
        let initialWindowID = try await tmux.ensureServer(
            server: tmuxServer,
            session: "main",
            cwd: worktreePath,
            cols: resolvedCols,
            rows: resolvedRows
        )

        let terminalID = UUID()
        let markerPath = Self.preSessionMarkerPath(worktreeID: worktreeID)
        // Delete any stale marker from a previous run of this worktree ID.
        try? FileManager.default.removeItem(atPath: markerPath)

        let command = Self.preSessionCommand(
            hookPath: hookPath,
            runtimeDir: Self.preSessionRuntimeDir,
            markerPath: markerPath,
            shell: defaultShell
        )
        // Full hook environment per docs/worktree-hooks.md. TBD_WORKTREE_NAME
        // uses `worktree.name` to match the archive hook's env (the display
        // name can be renamed later; the folder name is the stable identity).
        let env: [String: String] = [
            "TBD_WORKTREE_ID": worktreeID.uuidString,
            "TBD_TERMINAL_ID": terminalID.uuidString,
            "TBD_EVENT": HookEvent.preSession.rawValue,
            "TBD_WORKTREE_NAME": worktree.name,
            "TBD_WORKTREE_PATH": worktreePath,
            "TBD_REPO_PATH": repo.path,
            "TBD_BRANCH": worktree.branch,
        ]
        let window = try await tmux.createWindow(
            server: tmuxServer,
            session: "main",
            cwd: worktreePath,
            shellCommand: command,
            env: env,
            cols: resolvedCols,
            rows: resolvedRows
        )
        _ = try await db.terminals.create(
            id: terminalID,
            worktreeID: worktreeID,
            tmuxWindowID: window.windowID,
            tmuxPaneID: window.paneID,
            label: TerminalLabel.preSession,
            kind: .shell
        )
        // The pre-session terminal is the only tab until phase 3 runs.
        try await db.worktrees.setTabOrder(worktreeID: worktreeID, tabIDs: [terminalID])
        try await db.worktrees.setActiveTabID(worktreeID: worktreeID, tabID: terminalID)

        // Kill the untracked initial window now that a real window exists.
        if let initialWindowID {
            try? await tmux.killWindow(server: tmuxServer, windowID: initialWindowID)
        }

        logger.info("preSession hook \(hookPath, privacy: .public) spawned for worktree \(worktreeID, privacy: .public); gating primary terminals on marker")
        return PreSessionSpawn(
            terminalID: terminalID,
            windowID: window.windowID,
            paneID: window.paneID,
            markerPath: markerPath,
            hookPath: hookPath
        )
    }

    // MARK: - Phase 3: marker wait + primary spawn

    /// Reads + deletes the marker file if present, returning the recorded
    /// exit code. Returns nil when no marker exists yet.
    private static func consumeMarker(atPath path: String) -> PreSessionOutcome? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: path)
        let code = Int(content.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        return .completed(exitCode: code)
    }

    /// Polls for the completion marker. Short-circuits when the hook's tmux
    /// window disappears (user killed the pane). Reads + deletes the marker.
    func waitForPreSessionCompletion(
        preSession: PreSessionSpawn, tmuxServer: String
    ) async -> PreSessionOutcome {
        let deadline = Date().addingTimeInterval(preSessionTimeout)
        let pollNanos = UInt64(max(preSessionPollInterval, 0.01) * 1_000_000_000)
        while Date() < deadline {
            // Marker check first: if the hook finished and the user then
            // closed the pane, the recorded exit code wins.
            if let outcome = Self.consumeMarker(atPath: preSession.markerPath) {
                return outcome
            }
            let windowAlive = await tmux.windowExists(
                server: tmuxServer, windowID: preSession.windowID
            )
            if !windowAlive {
                // Same-iteration race: the hook can write the marker after the
                // fileExists check above and exit (closing the pane) before the
                // windowExists check. Re-check the marker once so a hook that
                // actually finished isn't misreported as a killed pane.
                if let outcome = Self.consumeMarker(atPath: preSession.markerPath) {
                    return outcome
                }
                return .paneKilled
            }
            try? await Task.sleep(nanoseconds: pollNanos)
        }
        // Deadline race: the marker may have landed during the final poll
        // sleep. Honor a hook that finished (just barely too late) instead of
        // reporting a timeout — and consume the marker so it never leaks.
        if let outcome = Self.consumeMarker(atPath: preSession.markerPath) {
            return outcome
        }
        return .timedOut
    }

    /// Phase 3: await the pre-session hook, notify on failure/timeout, then
    /// spawn the primary terminals regardless of hook outcome.
    ///
    /// Never throws and never deletes the worktree row — by the time phase 3
    /// runs, the git checkout is valid. Spawn errors are logged + notified.
    /// `completionAction` decides the final status flip (`.markActive` on the
    /// create path, `.revive` on the revive path); it always runs no matter
    /// what happened, so the row never sticks in `.creating`.
    func runPreSessionPhase3(
        preSession: PreSessionSpawn,
        worktree: Worktree, repo: Repo,
        worktreePath: String,
        skipClaude: Bool,
        archivedClaudeSessions: [String]? = nil,
        initialPrompt: String? = nil,
        cols: Int? = nil, rows: Int? = nil,
        completionAction: PreSessionCompletionAction
    ) async {
        let outcome = await waitForPreSessionCompletion(
            preSession: preSession, tmuxServer: worktree.tmuxServer
        )
        // The marker must never outlive the wait, whatever the outcome —
        // `.completed` consumes it inside the wait; this catches any straggler
        // written between the wait's last check and now.
        try? FileManager.default.removeItem(atPath: preSession.markerPath)

        // The worktree row can vanish mid-wait (repo remove cascades a
        // deleteForRepo while phase 3 is parked on the marker). Spawning the
        // primary terminals would then fail the terminal FK insert AFTER the
        // tmux window (and its Claude process) was created — orphaning both.
        // Bail out before any spawn: kill the pre-session window best-effort
        // and clean the marker; there is no row left to flip or notify.
        guard (try? await db.worktrees.get(id: worktree.id)) ?? nil != nil else {
            logger.warning("phase-3: worktree \(worktree.id, privacy: .public) row disappeared mid-wait — skipping primary spawn and cleaning up")
            try? await tmux.killWindow(
                server: worktree.tmuxServer, windowID: preSession.windowID
            )
            try? FileManager.default.removeItem(atPath: preSession.markerPath)
            return
        }

        switch outcome {
        case .completed(exitCode: 0):
            logger.info("preSession hook completed for worktree \(worktree.id, privacy: .public)")
        case .completed(let exitCode):
            await notifyPreSessionProblem(
                worktree: worktree, terminalID: preSession.terminalID,
                message: "Pre-session hook failed (exit \(exitCode)) — starting the agent anyway"
            )
        case .timedOut:
            await notifyPreSessionProblem(
                worktree: worktree, terminalID: preSession.terminalID,
                message: "Pre-session hook timed out after \(Int(preSessionTimeout))s — starting the agent anyway"
            )
        case .paneKilled:
            await notifyPreSessionProblem(
                worktree: worktree, terminalID: preSession.terminalID,
                message: "Pre-session hook terminal closed before the hook finished — starting the agent anyway"
            )
        }

        do {
            let created = try await spawnPrimaryTerminals(
                worktree: worktree, repo: repo,
                worktreePath: worktreePath,
                skipClaude: skipClaude,
                archivedClaudeSessions: archivedClaudeSessions,
                initialPrompt: initialPrompt,
                cols: cols, rows: rows,
                preSessionTerminalID: preSession.terminalID
            )
            for terminal in created {
                subscriptions?.broadcast(delta: .terminalCreated(TerminalDelta(
                    terminalID: terminal.id,
                    worktreeID: worktree.id,
                    label: terminal.label
                )))
            }
        } catch {
            logger.error("phase-3 primary terminal spawn failed for worktree \(worktree.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            await notifyPreSessionProblem(
                worktree: worktree, terminalID: preSession.terminalID,
                message: "Failed to start agent terminals after the pre-session hook: \(error.localizedDescription)"
            )
        }

        // Never leave the worktree stuck in .creating — the checkout is valid.
        do {
            switch completionAction {
            case .markActive:
                try await db.worktrees.updateStatus(id: worktree.id, status: .active)
            case .revive(let clearSessions):
                try await db.worktrees.revive(id: worktree.id, clearSessions: clearSessions)
            }
        } catch {
            logger.error("phase-3 status update failed for worktree \(worktree.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Records a daemon notification and broadcasts it (same pattern as
    /// `handleNotify` in RPCRouter+TerminalHandlers).
    private func notifyPreSessionProblem(
        worktree: Worktree, terminalID: UUID, message: String
    ) async {
        logger.warning("preSession: \(message, privacy: .public) (worktree \(worktree.id, privacy: .public))")
        do {
            let notification = try await db.notifications.create(
                worktreeID: worktree.id,
                type: .error,
                message: message,
                terminalID: terminalID
            )
            subscriptions?.broadcast(delta: .notificationReceived(NotificationDelta(
                notificationID: notification.id, worktreeID: notification.worktreeID,
                type: notification.type, message: notification.message,
                terminalID: notification.terminalID
            )))
        } catch {
            logger.error("failed to record preSession notification: \(error.localizedDescription, privacy: .public)")
        }
    }
}
