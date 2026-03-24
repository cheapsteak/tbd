import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+Notifications")

extension AppState {
    // MARK: - Notification Actions

    /// Send a notification.
    func notify(worktreeID: UUID?, type: NotificationType, message: String? = nil) async {
        do {
            try await daemonClient.notify(worktreeID: worktreeID, type: type, message: message)
        } catch {
            logger.error("Failed to send notification: \(error)")
            handleConnectionError(error)
        }
    }

    /// Mark all notifications for a worktree as read.
    func markNotificationsRead(worktreeID: UUID) async {
        do {
            try await daemonClient.markNotificationsRead(worktreeID: worktreeID)
            notifications[worktreeID] = nil
        } catch {
            // Not critical — just clear locally
            logger.warning("Failed to mark notifications read for \(worktreeID): \(error)")
            notifications[worktreeID] = nil
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

    // MARK: - Helpers

    func handleConnectionError(_ error: Error) {
        if let dcError = error as? DaemonClientError {
            switch dcError {
            case .daemonNotRunning, .connectionFailed:
                isConnected = false
            default:
                break
            }
        }
    }

    func showAlert(_ message: String, isError: Bool = false) {
        alertMessage = message
        alertIsError = isError
    }
}
