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
        // Same response, second reading: what commit the daemon was built from
        // and what it last saw on the remote. Carried on `daemon.status` rather
        // than fetched separately so the two banners can never disagree about
        // which daemon they are describing.
        daemonBuildIdentity = status.buildIdentity
        daemonUpdateStatus = status.update
        guard message != daemonBuildMismatchMessage else { return }
        daemonBuildMismatchMessage = message
        // A new (or cleared) verdict invalidates a previous dismissal.
        daemonBuildMismatchDismissed = false
        if let message {
            logger.warning("Daemon build skew detected: \(message, privacy: .public)")
        }
    }

    /// The update banner's text, or nil when there is nothing to say or the
    /// user has already dismissed this exact commit.
    ///
    /// Computed rather than stored so the dismissal and the observation cannot
    /// drift apart: a new commit arriving makes the banner reappear by itself,
    /// because the dismissal names the commit it dismissed.
    var updateNoticeMessage: String? {
        guard let latest = daemonUpdateStatus?.latestCommit,
              latest != dismissedUpdateCommit
        else { return nil }
        return UpdateNotice.message(
            daemon: daemonBuildIdentity, update: daemonUpdateStatus)
    }

    /// Dismiss the update notice for the commit it is currently about.
    func dismissUpdateNotice() {
        dismissedUpdateCommit = daemonUpdateStatus?.latestCommit
    }

    /// Ask the daemon to check the remote right now and report the answer as a
    /// toast. The app's "Check for Updates…" menu item.
    ///
    /// Deliberately reports in every case, including "up to date" — an
    /// unprompted banner earns its silence, a requested check does not.
    func checkForUpdatesNow() async {
        do {
            let status = try await updateCheckRunner()
            daemonUpdateStatus = status
            // A fresh observation of a commit the user dismissed earlier stays
            // dismissed for the banner; the toast still answers the question.
            showTransientToast(
                UpdateNotice.checkResultToast(daemon: daemonBuildIdentity, update: status),
                style: status.relation == .behind ? .notice : .success)
        } catch {
            logger.error("Update check failed: \(error, privacy: .public)")
            showErrorToast("Could not check for updates: \(error.localizedDescription)")
        }
    }

    /// Persist the update mode, then re-fetch capabilities so the Settings
    /// picker reflects the daemon's stored state. Applies at the daemon's next
    /// check.
    func setUpdateMode(_ mode: UpdateMode) async {
        do {
            try await updateModeSetter(mode)
            await refreshDaemonCapabilities()
        } catch {
            logger.error("Failed to set update mode: \(error, privacy: .public)")
            showAlert("Failed to set update mode: \(error.localizedDescription)", isError: true)
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
