import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+Terminals")

extension AppState {
    /// Resolve a terminal only within its owning worktree bucket. Terminal IDs
    /// are globally unique in normal operation, but persisted split layouts can
    /// outlive terminal/worktree churn; scoped lookup prevents stale layouts
    /// from rendering another worktree's tmux window.
    func terminal(id: UUID, in worktreeID: UUID) -> Terminal? {
        terminals[worktreeID]?.first { $0.id == id }
    }

    func initialTabLabel(for terminal: Terminal) -> String? {
        terminal.kind == .codex || terminal.label == "Codex" ? terminal.label : nil
    }

    // MARK: - Terminal Actions

    /// Treat an explicit user interrupt as "not working" for Codex terminals.
    /// This clears the sidebar spinner immediately and mirrors the state to
    /// the daemon best-effort.
    func handleTerminalInterrupt(terminalID: UUID) {
        guard let terminal = terminals.values.flatMap({ $0 })
            .first(where: { $0.id == terminalID }),
              terminal.kind == .codex || terminal.label == "Codex"
        else {
            return
        }

        if let idx = terminals[terminal.worktreeID]?.firstIndex(where: { $0.id == terminalID }) {
            terminals[terminal.worktreeID]?[idx].activityState = .idle
        }

        Task {
            do {
                try await daemonClient.setTerminalActivity(
                    terminalID: terminalID,
                    activityState: .idle
                )
            } catch {
                logger.debug("Failed to publish terminal interrupt state: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Create a terminal in a worktree and add a new tab for it.
    func createTerminal(worktreeID: UUID, cmd: String? = nil) async {
        do {
            let size = mainAreaTerminalSize()
            let colorFgBg = appearance?.currentColorFgBg
            let terminal = try await daemonClient.createTerminal(worktreeID: worktreeID, cmd: cmd, cols: size.cols, rows: size.rows, colorFgBg: colorFgBg)
            terminals[worktreeID, default: []].append(terminal)
            let tab = Tab(id: terminal.id, content: .terminal(terminalID: terminal.id), label: initialTabLabel(for: terminal))
            tabs[worktreeID, default: []].append(tab)
        } catch {
            logger.error("Failed to create terminal: \(error)")
            handleConnectionError(error)
        }
    }

    /// Create a terminal via the daemon without adding a tab.
    /// Used when splitting an existing tab — the terminal lives inside
    /// the parent tab's layout tree, not as its own tab.
    func createTerminalForSplit(worktreeID: UUID) async -> Terminal? {
        do {
            let size = mainAreaTerminalSize()
            let colorFgBg = appearance?.currentColorFgBg
            let terminal = try await daemonClient.createTerminal(worktreeID: worktreeID, cols: size.cols, rows: size.rows, colorFgBg: colorFgBg)
            terminals[worktreeID, default: []].append(terminal)
            return terminal
        } catch {
            logger.error("Failed to create terminal for split: \(error)")
            handleConnectionError(error)
            return nil
        }
    }

    /// Delete a terminal (kills tmux window and removes from daemon DB).
    func deleteTerminal(terminalID: UUID, worktreeID: UUID) async {
        do {
            try await daemonClient.deleteTerminal(terminalID: terminalID)
            terminals[worktreeID]?.removeAll { $0.id == terminalID }
        } catch {
            logger.error("Failed to delete terminal: \(error)")
            handleConnectionError(error)
        }
    }

    /// Send text to a terminal.
    func sendToTerminal(terminalID: UUID, text: String) async {
        do {
            try await daemonClient.sendToTerminal(terminalID: terminalID, text: text)
        } catch {
            logger.error("Failed to send to terminal: \(error)")
            handleConnectionError(error)
        }
    }

    /// Recreate a dead tmux window for an existing terminal.
    /// The daemon creates a new tmux window and updates the terminal record.
    /// A state refresh picks up the new tmuxWindowID, causing the view to rebuild.
    func recreateTerminalWindow(terminalID: UUID) async {
        guard !recreatingTerminalIDs.contains(terminalID) else { return }
        recreatingTerminalIDs.insert(terminalID)
        defer { recreatingTerminalIDs.remove(terminalID) }

        do {
            let size = mainAreaTerminalSize()
            let updated = try await daemonClient.recreateTerminalWindow(terminalID: terminalID, cols: size.cols, rows: size.rows)
            // Update local state so the view rebuilds with the new tmuxWindowID
            if let idx = terminals[updated.worktreeID]?.firstIndex(where: { $0.id == terminalID }) {
                terminals[updated.worktreeID]?[idx] = updated
            }
        } catch {
            logger.error("Failed to recreate terminal window: \(error)")
            handleConnectionError(error)
        }
    }

    /// Create a Claude terminal in a worktree and add a new tab for it.
    /// `profileID` pins the session to a specific model profile; when nil the
    /// daemon resolves the profile normally (repo override → global default →
    /// keychain login).
    func createClaudeTerminal(worktreeID: UUID, profileID: UUID? = nil) async {
        do {
            let size = mainAreaTerminalSize()
            let colorFgBg = appearance?.currentColorFgBg
            let terminal = try await daemonClient.createTerminal(
                worktreeID: worktreeID,
                cmd: nil,
                type: .claude,
                overrideProfileID: profileID,
                cols: size.cols,
                rows: size.rows,
                colorFgBg: colorFgBg
            )
            terminals[worktreeID, default: []].append(terminal)
            let tab = Tab(id: terminal.id, content: .terminal(terminalID: terminal.id), label: initialTabLabel(for: terminal))
            tabs[worktreeID, default: []].append(tab)
        } catch {
            logger.error("Failed to create Claude terminal: \(error)")
            handleConnectionError(error)
        }
    }

    /// Create a Codex terminal in a worktree and add a new tab for it.
    func createCodexTerminal(worktreeID: UUID) async {
        do {
            let size = mainAreaTerminalSize()
            let colorFgBg = appearance?.currentColorFgBg
            let terminal = try await daemonClient.createTerminal(
                worktreeID: worktreeID,
                cmd: nil,
                type: .codex,
                cols: size.cols,
                rows: size.rows,
                colorFgBg: colorFgBg
            )
            terminals[worktreeID, default: []].append(terminal)
            let tab = Tab(id: terminal.id, content: .terminal(terminalID: terminal.id), label: initialTabLabel(for: terminal))
            tabs[worktreeID, default: []].append(tab)
        } catch {
            logger.error("Failed to create Codex terminal: \(error)")
            handleConnectionError(error)
        }
    }

    /// Fork a Claude terminal by resuming from an existing session ID.
    func forkClaudeTerminal(worktreeID: UUID, sessionID: String, tokenID: UUID? = nil) async {
        do {
            let size = mainAreaTerminalSize()
            let colorFgBg = appearance?.currentColorFgBg
            let terminal = try await daemonClient.createTerminal(
                worktreeID: worktreeID,
                resumeSessionID: sessionID,
                overrideProfileID: tokenID,
                cols: size.cols,
                rows: size.rows,
                colorFgBg: colorFgBg
            )
            terminals[worktreeID, default: []].append(terminal)
            let tab = Tab(id: terminal.id, content: .terminal(terminalID: terminal.id), label: initialTabLabel(for: terminal))
            tabs[worktreeID, default: []].append(tab)
        } catch {
            logger.error("Failed to fork Claude terminal: \(error)")
            handleConnectionError(error)
        }
    }

    /// Toggle pin state for a terminal.
    func setTerminalPin(id: UUID, pinned: Bool) async {
        // Optimistic local update
        for worktreeID in terminals.keys {
            if let idx = terminals[worktreeID]?.firstIndex(where: { $0.id == id }) {
                terminals[worktreeID]?[idx].pinnedAt = pinned ? Date() : nil
            }
        }

        do {
            try await daemonClient.setTerminalPin(id: id, pinned: pinned)
        } catch {
            logger.error("Failed to set terminal pin: \(error)")
            handleConnectionError(error)
        }
    }
}
