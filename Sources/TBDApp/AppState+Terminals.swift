import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+Terminals")

extension AppState {
    // MARK: - Terminal Actions

    /// Create a terminal in a worktree and add a new tab for it.
    func createTerminal(worktreeID: UUID, cmd: String? = nil) async {
        do {
            let terminal = try await daemonClient.createTerminal(worktreeID: worktreeID, cmd: cmd)
            terminals[worktreeID, default: []].append(terminal)
            let tab = Tab(id: terminal.id, content: .terminal(terminalID: terminal.id))
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
            let terminal = try await daemonClient.createTerminal(worktreeID: worktreeID)
            terminals[worktreeID, default: []].append(terminal)
            return terminal
        } catch {
            logger.error("Failed to create terminal for split: \(error)")
            handleConnectionError(error)
            return nil
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
}
