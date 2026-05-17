import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "SuspendResume")

/// Thread-safe ISO8601 timestamp formatter for debug logging.
private final class SuspendLogFormatter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    func timestamp() -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: Date())
    }
}

/// File-based debug log for suspend/resume diagnostics (os_log not reliably captured)
private let suspendLogFormatter = SuspendLogFormatter()
private func suspendLog(_ msg: String) {
    let line = "[SR \(suspendLogFormatter.timestamp())] \(msg)\n"
    if let data = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: "/tmp/tbd-suspend.log") {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: "/tmp/tbd-suspend.log", contents: data)
        }
    }
}

public enum ManualSuspendResult: Equatable, Sendable {
    case ok
    case alreadySuspended
    case notClaudeTerminal
    case notFound
}

public enum ManualResumeResult: Equatable, Sendable {
    case ok
    case notSuspended
    case notFound
    case noSessionID
}

public actor SuspendResumeCoordinator {
    private let db: TBDDatabase
    private let tmux: TmuxManager
    private let detector: ClaudeStateDetector
    private let modelProfileResolver: ModelProfileResolver?

    /// The user's default shell (from $SHELL, falls back to /bin/zsh).
    private var defaultShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    public init(db: TBDDatabase, tmux: TmuxManager, modelProfileResolver: ModelProfileResolver? = nil) {
        self.db = db
        self.tmux = tmux
        self.detector = ClaudeStateDetector(tmux: tmux)
        self.modelProfileResolver = modelProfileResolver
    }

    /// Called when the daemon receives a response_complete notification for a worktree.
    /// Preserved as a no-op entry point for future wiring (e.g. notification UI) — the
    /// auto-suspend consumer that previously read this signal was removed on 2026-05-17.
    public func responseCompleted(worktreeID: UUID) {
        suspendLog("responseCompleted for worktree \(worktreeID.uuidString.prefix(8))")
    }

    // MARK: - Manual Suspend/Resume

    // Auto-suspend was removed on 2026-05-17. If reintroduced, drive it from the
    // Stop hook (response_complete signal) rather than text-pattern matching
    // of tmux status bar text — the old text-matching approach broke whenever
    // Claude's CLI changed its status display.
    public func manualSuspend(terminalID: UUID) async -> ManualSuspendResult {
        guard let terminal = try? await db.terminals.get(id: terminalID) else {
            return .notFound
        }
        guard terminal.isClaudeResumable, let sessionID = terminal.claudeSessionID else {
            return .notClaudeTerminal
        }
        guard terminal.suspendedAt == nil else {
            return .alreadySuspended
        }
        guard let server = await worktreeServer(for: terminal.worktreeID) else {
            return .notFound
        }

        // Capture snapshot
        let snapshot: String?
        do {
            let captured = try await tmux.capturePaneWithAnsi(server: server, paneID: terminal.tmuxPaneID)
            snapshot = captured.isEmpty ? nil : captured
        } catch {
            snapshot = nil
        }

        // Send /exit
        suspendLog("MANUAL SUSPENDING \(terminalID.uuidString.prefix(8)): sending /exit")
        do {
            try await tmux.sendCommand(server: server, paneID: terminal.tmuxPaneID, command: "/exit")
        } catch {
            return .notFound
        }

        // Mark suspended immediately so the app switches to snapshot view
        // without waiting for verify-exit polling.
        do {
            try await db.terminals.setSuspended(id: terminalID, sessionID: sessionID, snapshot: snapshot)
        } catch {
            suspendLog("MANUAL SUSPEND: failed to mark suspended for \(terminalID.uuidString.prefix(8))")
        }

        // Verify exit: poll for up to 3s
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(200))
            if let cmd = try? await tmux.paneCurrentCommand(server: server, paneID: terminal.tmuxPaneID),
               !ClaudeStateDetector.isClaudeProcess(cmd) {
                break
            }
        }

        return .ok
    }

    public func manualResume(terminalID: UUID) async -> ManualResumeResult {
        guard let terminal = try? await db.terminals.get(id: terminalID) else {
            return .notFound
        }
        guard terminal.suspendedAt != nil else {
            return .notSuspended
        }
        guard terminal.isClaudeResumable else {
            return .noSessionID
        }
        guard await worktreeServer(for: terminal.worktreeID) != nil else {
            return .notFound
        }

        await resumeTerminal(terminal)
        return .ok
    }

    // MARK: - Resume

    private func resumeTerminal(_ terminal: Terminal) async {
        guard let server = await worktreeServer(for: terminal.worktreeID),
              let sessionID = terminal.claudeSessionID else { return }

        // Step 1: Check if Claude is still running (pending /exit or user restarted)
        if let cmd = try? await tmux.paneCurrentCommand(server: server, paneID: terminal.tmuxPaneID),
           ClaudeStateDetector.isClaudeProcess(cmd) {
            // Wait up to 5s for queued /exit to process
            var stillRunning = true
            for _ in 0..<25 {
                try? await Task.sleep(for: .milliseconds(200))
                if let cmd = try? await tmux.paneCurrentCommand(server: server, paneID: terminal.tmuxPaneID),
                   !ClaudeStateDetector.isClaudeProcess(cmd) {
                    stillRunning = false
                    break
                }
            }
            if stillRunning {
                // User restarted it — clear and re-capture
                try? await db.terminals.clearSuspended(id: terminal.id)
                if let newID = await detector.captureSessionID(server: server, paneID: terminal.tmuxPaneID) {
                    try? await db.terminals.updateSessionID(id: terminal.id, sessionID: newID)
                }
                return
            }
        }

        // Step 2-4: Create new tmux window with resume command
        guard let worktree = try? await db.worktrees.get(id: terminal.worktreeID) else {
            return
        }

        // Bootstrap the tmux server before creating the resume window. After a
        // reboot the server is dead (tmux servers don't survive a restart), so
        // `createWindow` → `new-window` would throw "no server running on …" and
        // on-demand Resume would silently fail. `ensureServer` (no-op if the
        // session already exists) brings up `new-session -d -s main` first.
        // It returns the bootstrap window ID ONLY when it created a new session;
        // we must kill that placeholder after the real window exists (killing it
        // earlier collapses the only-window session and exits the server). This
        // deferred-kill bootstrap dance is what lets on-demand Resume be the sole
        // post-reboot recovery path now that reconcile parks instead of recreating
        // (#284).
        let bootstrapWindowID: String?
        do {
            bootstrapWindowID = try await tmux.ensureServer(
                server: server, session: "main", cwd: worktree.path
            )
        } catch {
            // Server bootstrap failed — abort gracefully rather than crash.
            // The terminal stays suspended; the next Resume attempt retries.
            logger.warning("Failed to bootstrap tmux server for resume of terminal \(terminal.id): \(error)")
            return
        }

        // Honor per-terminal model profile. We use loadByID (NOT resolve(repoID:))
        // to load the EXACT profile persisted on this terminal — a re-resolution
        // could pick a different override if the user changed defaults since
        // suspend. Failures degrade gracefully to keychain login.
        var resolvedProfile: ResolvedModelProfile? = nil
        if let profileID = terminal.profileID, let resolver = modelProfileResolver {
            do {
                resolvedProfile = try await resolver.loadByID(profileID)
                if resolvedProfile == nil {
                    logger.warning("model profile \(profileID, privacy: .public) for terminal \(terminal.id, privacy: .public) is missing; falling back to keychain login")
                }
            } catch {
                logger.warning("model profile lookup failed for terminal \(terminal.id, privacy: .public); falling back to keychain login: \(error.localizedDescription, privacy: .public)")
                resolvedProfile = nil
            }
        }

        let resumeConfig = try? await db.config.get()
        let claudeEnvOverrides = resumeConfig?.envSettingOverrides ?? [:]
        // Free-form env overrides (global < repo < profile), layered under the
        // builder's auth/routing env below so resumed sessions keep them too.
        let resumeRepo = try? await db.repos.get(id: worktree.repoID)
        let mergedEnvOverrides = EnvOverrideResolver.merge(
            global: resumeConfig?.envOverrides,
            repo: resumeRepo?.envOverrides,
            profile: resolvedProfile?.envOverrides
        )
        // resolveOverlayPath never throws — it degrades to the global hooks-only
        // overlay if the per-session write fails, so resume always proceeds.
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
        // Inject TBD_WORKTREE_ID + TBD_TERMINAL_ID into the resumed pane so
        // notifications and the SessionStart hook bridge attribute to the
        // right terminal even after the post-resume session-id rollover.
        let resumeEnv: [String: String] = [
            "TBD_WORKTREE_ID": worktree.id.uuidString,
            "TBD_TERMINAL_ID": terminal.id.uuidString,
        ]
        do {
            let window = try await tmux.createWindow(
                server: server, session: "main",
                cwd: worktree.path, shellCommand: spawn.command,
                env: resumeEnv,
                sensitiveEnv: mergedEnvOverrides.merging(spawn.sensitiveEnv) { _, builder in builder }
            )
            // Now that the real window exists, kill the bootstrap placeholder
            // (if we created one). The session keeps the freshly-created window,
            // so it — and the server — stay alive. Best-effort: a leftover empty
            // window is reaped by reconcile's orphan-window cleanup.
            if let bootstrapWindowID {
                try? await tmux.killWindow(server: server, windowID: bootstrapWindowID)
            }
            try await db.terminals.updateTmuxIDs(
                id: terminal.id, windowID: window.windowID, paneID: window.paneID
            )
            // Clear suspendedAt immediately. The snapshot stays in the DB so the
            // app can feed it into TerminalPanelView as initial content — the live
            // tmux output then overwrites it seamlessly.
            // Note: snapshot persists until overwritten by the next suspend. After a
            // resume, every subsequent view recreation (tab switches, worktree
            // navigation, app restarts) briefly shows this snapshot until live tmux
            // output arrives. Brief stale content is better than a blank screen.
            do {
                try await db.terminals.clearSuspended(id: terminal.id)
            } catch {
                // If this fails, suspendedAt stays set — the sidebar shows a stale
                // pause icon and the terminal won't be resumable again until a restart.
                suspendLog("Failed to clear suspended for \(terminal.id.uuidString.prefix(8)): \(error)")
            }
            suspendLog("Resumed terminal \(terminal.id.uuidString.prefix(8)) in window \(window.windowID)")

            let termID = terminal.id
            let paneID = window.paneID
            // After resume, `claude --resume <oldID>` forks the conversation into
            // a new session file. Wait for Claude to settle, then re-capture the
            // new session ID so subsequent suspends/resumes reference the live
            // session.
            Task {
                try? await Task.sleep(for: .seconds(5))
                if let newID = await self.detector.captureSessionID(server: server, paneID: paneID) {
                    try? await self.db.terminals.updateSessionID(id: termID, sessionID: newID)
                    suspendLog("Re-captured session ID for \(termID.uuidString.prefix(8)): \(newID)")
                } else {
                    suspendLog("Failed to re-capture session ID for \(termID.uuidString.prefix(8))")
                }
            }
        } catch {
            // If we just bootstrapped the server and createWindow failed, the
            // server is alive with only the placeholder window — a half-up state
            // the next reconcile would misread (serverAlive + stale window gone)
            // and route to the dead-window path. Kill the server so the next
            // reconcile re-enters reboot recovery instead.
            if bootstrapWindowID != nil {
                try? await tmux.killServer(server: server)
            }
            logger.warning("Failed to resume terminal \(terminal.id): \(error)")
        }
    }

    // MARK: - Startup Reconciliation

    /// Clear stale `suspendedAt` for terminals whose Claude process is still
    /// alive (e.g. daemon crashed mid-suspend before /exit landed).
    public func reconcileOnStartup() async {
        guard let allTerminals = try? await db.terminals.list() else { return }

        for terminal in allTerminals where terminal.suspendedAt != nil {
            guard let server = await worktreeServer(for: terminal.worktreeID) else { continue }
            let alive = await tmux.windowExists(server: server, windowID: terminal.tmuxWindowID)
            if alive, let cmd = try? await tmux.paneCurrentCommand(server: server, paneID: terminal.tmuxPaneID),
               ClaudeStateDetector.isClaudeProcess(cmd) {
                try? await db.terminals.clearSuspended(id: terminal.id)
                logger.info("Startup: cleared suspendedAt for running terminal \(terminal.id)")
            }
        }
    }

    // MARK: - Helpers

    private func worktreeServer(for worktreeID: UUID) async -> String? {
        guard let wt = try? await db.worktrees.get(id: worktreeID) else { return nil }
        return wt.tmuxServer
    }
}
