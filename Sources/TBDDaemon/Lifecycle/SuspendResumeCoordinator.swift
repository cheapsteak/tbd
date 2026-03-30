import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "SuspendResume")

public actor SuspendResumeCoordinator {
    private let db: TBDDatabase
    private let tmux: TmuxManager
    private let detector: ClaudeStateDetector
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    private var lastKnownSelection: Set<UUID> = []

    public init(db: TBDDatabase, tmux: TmuxManager) {
        self.db = db
        self.tmux = tmux
        self.detector = ClaudeStateDetector(tmux: tmux)
    }

    public func selectionChanged(to newSelection: Set<UUID>) {
        let departing = lastKnownSelection.subtracting(newSelection)
        let arriving = newSelection.subtracting(lastKnownSelection)
        lastKnownSelection = newSelection

        for worktreeID in departing {
            scheduleSuspend(worktreeID: worktreeID)
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

        // Cancellable phase: idle check with 1s debounce
        guard await detector.isIdleConfirmed(server: server, paneID: terminal.tmuxPaneID) else { return }
        guard !Task.isCancelled else { return }

        // POINT OF NO RETURN — send /exit
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
            try await db.terminals.setSuspended(id: terminal.id, sessionID: terminal.claudeSessionID!)
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
            try await db.terminals.clearSuspended(id: terminal.id)
            logger.info("Resumed terminal \(terminal.id) in window \(window.windowID)")

            // Re-capture session ID after ~5s
            let termID = terminal.id
            let paneID = window.paneID
            Task {
                try? await Task.sleep(for: .seconds(5))
                if let newID = await self.detector.captureSessionID(server: server, paneID: paneID) {
                    try? await self.db.terminals.updateSessionID(id: termID, sessionID: newID)
                    logger.info("Re-captured session ID for terminal \(termID): \(newID)")
                } else {
                    logger.warning("Failed to re-capture session ID for terminal \(termID)")
                }
            }
        } catch {
            logger.warning("Failed to resume terminal \(terminal.id): \(error)")
        }

        inFlight[terminal.id] = nil
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
    }

    // MARK: - Helpers

    private func worktreeServer(for worktreeID: UUID) async -> String? {
        guard let wt = try? await db.worktrees.get(id: worktreeID) else { return nil }
        return wt.tmuxServer
    }
}
