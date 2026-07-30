import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+Notifications")

extension AppState {
    // MARK: - Notification Actions

    /// Send a notification.
    func notify(worktreeID: UUID?, type: NotificationType, message: String? = nil,
                terminalID: UUID? = nil) async {
        do {
            try await daemonClient.notify(worktreeID: worktreeID, type: type,
                                          message: message, terminalID: terminalID)
        } catch {
            logger.error("Failed to send notification: \(error)")
            handleConnectionError(error)
        }
    }

    /// Mark all notifications for a worktree as read.
    func markNotificationsRead(worktreeID: UUID) async {
        do {
            try await daemonClient.markNotificationsRead(worktreeID: worktreeID)
            unreadByWorktree[worktreeID] = nil
        } catch {
            // Not critical — just clear locally
            logger.warning("Failed to mark notifications read for \(worktreeID): \(error)")
            unreadByWorktree[worktreeID] = nil
        }
    }

    // MARK: - Daemon Status

    /// Get daemon status info.
    func fetchDaemonStatus() async -> DaemonStatusResult? {
        do {
            let status = try await daemonClient.daemonStatus()
            isConnected = true
            return status
        } catch {
            logger.error("Failed to get daemon status: \(error)")
            handleConnectionError(error)
            return nil
        }
    }

    /// Compare the daemon's reported executable path against the daemon
    /// builds this app could legitimately be paired with, and publish a
    /// banner message on mismatch (see `DaemonBuildSkew`). Called on every
    /// successful connect. Visibility only — never restarts the daemon.
    func checkDaemonBuildIdentity() async {
        guard let status = try? await daemonClient.daemonStatus() else { return }
        let siblingDaemonPath = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("TBDDaemon").path
        let sourceWorktreePath = StatusBarView.resolveSourceWorktreePath(
            bundleURL: Bundle.main.bundleURL,
            executablePath: Bundle.main.executablePath
        )
        let message = DaemonBuildSkew.warningMessage(
            daemonExecutablePath: status.executablePath,
            appSiblingDaemonPath: siblingDaemonPath,
            sourceWorktreePath: sourceWorktreePath
        )
        guard message != daemonBuildMismatchMessage else { return }
        daemonBuildMismatchMessage = message
        // A new (or cleared) verdict invalidates a previous dismissal.
        daemonBuildMismatchDismissed = false
        if let message {
            logger.warning("Daemon build skew detected: \(message, privacy: .public)")
        }
    }

    // MARK: - Helpers

    /// Whether an error means "the daemon is gone" rather than "this one call
    /// failed". Only these two cases stop the poll timer; every other
    /// `DaemonClientError` — a decode failure, an RPC-level rejection, a
    /// timeout — leaves the app connected and the ~2s poll running, so the
    /// caller keeps being re-driven.
    ///
    /// Shared so retry budgets and the connection flag cannot disagree about
    /// what counts as a disconnect: a budget that forgave *every* error would
    /// never bite on the persistent per-worktree failures this does not cover.
    static func isDisconnectError(_ error: Error) -> Bool {
        guard let dcError = error as? DaemonClientError else { return false }
        switch dcError {
        case .daemonNotRunning, .connectionFailed:
            return true
        default:
            return false
        }
    }

    func handleConnectionError(_ error: Error) {
        if Self.isDisconnectError(error) {
            isConnected = false
        }
    }

    func showAlert(_ message: String, isError: Bool = false) {
        alertMessage = message
        alertIsError = isError
    }
}
