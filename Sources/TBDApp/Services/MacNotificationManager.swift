import Foundation
import UserNotifications
import SwiftUI
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "MacNotificationManager")

@MainActor
final class MacNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    @AppStorage("enableNotifications") private var enabled: Bool = true

    private var hasRequestedPermission = false
    private var hasLoggedUnavailable = false

    /// Set by `AppState` after construction so banner clicks can drive navigation.
    /// Weak to avoid a retain cycle — `AppState` owns this manager.
    weak var appState: AppState?

    func configure(appState: AppState) {
        self.appState = appState
    }

    /// UNUserNotificationCenter crashes unbundled executables (no CFBundleIdentifier).
    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    func requestPermissionIfNeeded() {
        guard !hasRequestedPermission else { return }
        guard isAvailable else {
            if !hasLoggedUnavailable {
                logger.error("Notification banners disabled: Bundle.main.bundleIdentifier is nil. App must be launched via the .app bundle (scripts/restart.sh).")
                hasLoggedUnavailable = true
            }
            return
        }
        hasRequestedPermission = true

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                logger.error("requestAuthorization failed: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                logger.error("requestAuthorization denied — banners will not appear. Enable in System Settings → Notifications → TBD.")
            }
        }
    }

    func postIfEnabled(worktreeID: UUID, message: String?, worktrees: [Worktree]) {
        guard enabled, isAvailable else { return }
        requestPermissionIfNeeded()

        let worktreeName = worktrees.first(where: { $0.id == worktreeID })?.displayName
            ?? worktreeID.uuidString

        let truncatedMessage: String
        if let msg = message, !msg.isEmpty {
            truncatedMessage = msg.count > 200 ? String(msg.prefix(200)) + "…" : msg
        } else {
            truncatedMessage = "Claude has finished responding."
        }

        let content = UNMutableNotificationContent()
        content.title = worktreeName
        content.body = truncatedMessage
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: worktreeID.uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Post error: \(error)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banners even when TBD is the frontmost app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        handler([.banner])
    }

    /// Parse a notification request identifier and navigate to the matching worktree.
    /// Factored out of the delegate method so it's testable without faking
    /// `UNNotificationResponse` (which has no public initializer).
    func handleClick(identifier: String) {
        guard let worktreeID = UUID(uuidString: identifier) else {
            logger.error("Banner click identifier is not a UUID: \(identifier, privacy: .public)")
            return
        }
        guard let appState else {
            logger.error("Banner click ignored: appState not configured")
            return
        }
        appState.navigateToWorktree(worktreeID)
    }

    /// Banner click → focus the worktree the notification was about.
    /// `nonisolated` to satisfy the protocol's isolation requirement, matching
    /// `willPresent` above. Hops back to the main actor to invoke `handleClick`.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        // Call the completion handler synchronously to satisfy its
        // non-Sendable isolation, then hop to the main actor for navigation.
        completionHandler()
        Task { @MainActor in
            self.handleClick(identifier: identifier)
        }
    }
}
