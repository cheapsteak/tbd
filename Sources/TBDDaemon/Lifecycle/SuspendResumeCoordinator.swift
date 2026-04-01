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

public actor SuspendResumeCoordinator {
    private let db: TBDDatabase
    private let tmux: TmuxManager
    private let detector: ClaudeStateDetector
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    private var lastKnownSelection: Set<UUID> = []
    /// Tracks whether each worktree has received a response_complete since last
    /// suspend or resume. Used as belt-and-suspenders: suspend requires BOTH
    /// this signal AND capture-pane confirmation.
    private var worktreeIdleFromHook: Set<UUID> = []

    public init(db: TBDDatabase, tmux: TmuxManager) {
        self.db = db
        self.tmux = tmux
        self.detector = ClaudeStateDetector(tmux: tmux)
    }

    /// Called when the daemon receives a response_complete notification for a worktree.
    /// This means a Claude instance in that worktree just finished a response and
    /// is now waiting for user input.
    public func responseCompleted(worktreeID: UUID) {
        worktreeIdleFromHook.insert(worktreeID)
        suspendLog("responseCompleted for worktree \(worktreeID.uuidString.prefix(8))")
    }

    public func selectionChanged(to newSelection: Set<UUID>, suspendEnabled: Bool = true) {
        let departing = lastKnownSelection.subtracting(newSelection)
        let arriving = newSelection.subtracting(lastKnownSelection)
        suspendLog("selectionChanged: departing=\(departing.map { $0.uuidString.prefix(8) }), arriving=\(arriving.map { $0.uuidString.prefix(8) }), suspendEnabled=\(suspendEnabled), idleHook=\(worktreeIdleFromHook.map { $0.uuidString.prefix(8) })")
        lastKnownSelection = newSelection

        if suspendEnabled {
            for worktreeID in departing {
                scheduleSuspend(worktreeID: worktreeID)
            }
        }
        for worktreeID in arriving {
            scheduleResume(worktreeID: worktreeID)
        }
    }

    // MARK: - Suspend

    private func scheduleSuspend(worktreeID: UUID) {
        Task {
            guard let terminals = try? await db.terminals.list(worktreeID: worktreeID) else { return }
            for terminal in terminals {
                guard terminal.label?.hasPrefix("claude") == true,
                      terminal.pinnedAt == nil,
                      terminal.suspendedAt == nil,
                      terminal.claudeSessionID != nil else { continue }

                inFlight[terminal.id]?.cancel()
                let task = Task<Void, Never> { await suspendTerminal(terminal) }
                inFlight[terminal.id] = task
            }
        }
    }

    private func suspendTerminal(_ terminal: Terminal) async {
        guard let server = await worktreeServer(for: terminal.worktreeID) else { return }

        // Belt: require that this worktree received a response_complete from Claude's
        // Stop hook. This confirms Claude finished a response and is waiting for input.
        // If the hook hasn't fired (e.g. daemon restarted, hook missed), do a
        // just-in-time capture-pane check to seed the idle flag.
        if !worktreeIdleFromHook.contains(terminal.worktreeID) {
            if await detector.isIdle(server: server, paneID: terminal.tmuxPaneID) {
                worktreeIdleFromHook.insert(terminal.worktreeID)
                suspendLog("Just-in-time seeded idle hook for worktree \(terminal.worktreeID.uuidString.prefix(8))")
            } else {
                suspendLog("SKIP \(terminal.id.uuidString.prefix(8)): no response_complete hook and capture-pane says not idle")
                return
            }
        }

        // Suspenders: capture-pane idle check with 1s debounce.
        // When the JIT path above fires, the first check here is redundant
        // (idle was just confirmed), but the 1s debounce still adds value —
        // it catches transitions from idle to busy between the JIT check
        // and the actual suspend.
        let idleConfirmed = await detector.isIdleConfirmed(server: server, paneID: terminal.tmuxPaneID)
        guard idleConfirmed else {
            suspendLog("SKIP \(terminal.id.uuidString.prefix(8)): capture-pane says not idle")
            return
        }
        guard !Task.isCancelled else {
            suspendLog("SKIP \(terminal.id.uuidString.prefix(8)): task cancelled")
            return
        }

        // Capture terminal snapshot with ANSI colors before exit
        let snapshot: String?
        do {
            let captured = try await tmux.capturePaneWithAnsi(server: server, paneID: terminal.tmuxPaneID)
            snapshot = captured.isEmpty ? nil : captured
            suspendLog("Captured snapshot for \(terminal.id.uuidString.prefix(8)): \(captured.count) chars")
        } catch {
            snapshot = nil
            suspendLog("Failed to capture snapshot for \(terminal.id.uuidString.prefix(8)): \(error)")
        }

        // POINT OF NO RETURN — send /exit
        suspendLog("SUSPENDING \(terminal.id.uuidString.prefix(8)): sending /exit")
        do {
            try await tmux.sendCommand(server: server, paneID: terminal.tmuxPaneID, command: "/exit")
        } catch {
            logger.warning("Failed to send /exit to terminal \(terminal.id): \(error)")
            return
        }

        // Verify exit: poll for up to 3s
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(200))
            if let cmd = try? await tmux.paneCurrentCommand(server: server, paneID: terminal.tmuxPaneID),
               !ClaudeStateDetector.isClaudeProcess(cmd) {
                break
            }
        }

        // Always mark suspended after point of no return
        do {
            try await db.terminals.setSuspended(id: terminal.id, sessionID: terminal.claudeSessionID!, snapshot: snapshot)
            worktreeIdleFromHook.remove(terminal.worktreeID)
            logger.info("Suspended terminal \(terminal.id)")
        } catch {
            logger.warning("Failed to mark terminal \(terminal.id) suspended: \(error)")
        }

        inFlight[terminal.id] = nil
    }

    // MARK: - Resume

    private func scheduleResume(worktreeID: UUID) {
        Task {
            guard let terminals = try? await db.terminals.list(worktreeID: worktreeID) else { return }
            for terminal in terminals where terminal.suspendedAt != nil {
                inFlight[terminal.id]?.cancel()
                let task = Task<Void, Never> { await resumeTerminal(terminal) }
                inFlight[terminal.id] = task
            }
        }
    }

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
                inFlight[terminal.id] = nil
                return
            }
        }

        // Step 2-4: Create new tmux window with resume command
        guard let worktree = try? await db.worktrees.get(id: terminal.worktreeID) else {
            inFlight[terminal.id] = nil
            return
        }

        let resumeCommand = "claude --resume \(sessionID) --dangerously-skip-permissions"
        do {
            let window = try await tmux.createWindow(
                server: server, session: "main",
                cwd: worktree.path, shellCommand: resumeCommand
            )
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
                // pause icon and scheduleSuspend (which guards on suspendedAt == nil)
                // won't cycle this terminal again until a restart.
                suspendLog("Failed to clear suspended for \(terminal.id.uuidString.prefix(8)): \(error)")
            }
            suspendLog("Resumed terminal \(terminal.id.uuidString.prefix(8)) in window \(window.windowID)")

            let termID = terminal.id
            let worktreeID = terminal.worktreeID
            let paneID = window.paneID
            // Track the post-resume task in inFlight so a rapid re-suspend
            // can cancel it — otherwise stale updateSessionID calls could
            // race with the new suspend cycle.
            inFlight[termID] = Task {
                // Wait for Claude to settle, then re-capture session ID
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                if let newID = await self.detector.captureSessionID(server: server, paneID: paneID) {
                    try? await self.db.terminals.updateSessionID(id: termID, sessionID: newID)
                    suspendLog("Re-captured session ID for \(termID.uuidString.prefix(8)): \(newID)")
                } else {
                    suspendLog("Failed to re-capture session ID for \(termID.uuidString.prefix(8))")
                }
                // Re-seed idle hook after a longer delay to avoid instant
                // re-suspension on brief worktree departures. 30s gives the user
                // time to settle before the terminal becomes eligible again.
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                if await self.detector.isIdle(server: server, paneID: paneID) {
                    self.worktreeIdleFromHook.insert(worktreeID)
                    suspendLog("Re-seeded idle hook for worktree \(worktreeID.uuidString.prefix(8)) after resume (delayed)")
                }
                self.inFlight[termID] = nil
            }
        } catch {
            logger.warning("Failed to resume terminal \(terminal.id): \(error)")
            inFlight[terminal.id] = nil
        }
    }

    // MARK: - Startup Reconciliation

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

        // Seed worktreeIdleFromHook for any worktree with a live, idle Claude terminal.
        // This handles the case where the daemon restarts while Claude is sitting idle —
        // without this, the in-memory flag would be empty and suspend would never trigger.
        for terminal in allTerminals {
            guard terminal.label?.hasPrefix("claude") == true,
                  terminal.suspendedAt == nil,
                  terminal.claudeSessionID != nil else { continue }
            guard let server = await worktreeServer(for: terminal.worktreeID) else { continue }
            if await detector.isIdle(server: server, paneID: terminal.tmuxPaneID) {
                worktreeIdleFromHook.insert(terminal.worktreeID)
                suspendLog("Startup: seeded idle hook for worktree \(terminal.worktreeID.uuidString.prefix(8))")
            }
        }

        // Backfill session IDs for pre-existing Claude terminals that lack one.
        // These were created before --session-id was added at terminal creation.
        for terminal in allTerminals {
            guard terminal.claudeSessionID == nil,
                  terminal.label?.hasPrefix("claude") == true,
                  terminal.suspendedAt == nil else { continue }
            guard let server = await worktreeServer(for: terminal.worktreeID) else { continue }
            let alive = await tmux.windowExists(server: server, windowID: terminal.tmuxWindowID)
            guard alive else { continue }
            if let sessionID = await detector.captureSessionID(server: server, paneID: terminal.tmuxPaneID) {
                try? await db.terminals.updateSessionID(id: terminal.id, sessionID: sessionID)
                logger.info("Startup: backfilled session ID for terminal \(terminal.id): \(sessionID)")
            }
        }
    }

    // MARK: - Helpers

    private func worktreeServer(for worktreeID: UUID) async -> String? {
        guard let wt = try? await db.worktrees.get(id: worktreeID) else { return nil }
        return wt.tmuxServer
    }
}
