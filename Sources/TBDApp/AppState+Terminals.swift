import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+Terminals")

extension AppState {
    // MARK: - Terminal Actions

    /// Create a terminal in a worktree.
    func createTerminal(worktreeID: UUID, cmd: String? = nil) async {
        do {
            let terminal = try await daemonClient.createTerminal(worktreeID: worktreeID, cmd: cmd)
            terminals[worktreeID, default: []].append(terminal)
        } catch {
            logger.error("Failed to create terminal: \(error)")
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
}
