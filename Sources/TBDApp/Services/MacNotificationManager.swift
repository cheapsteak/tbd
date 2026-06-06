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

    /// The banner title for a notification. Focus pushes get a distinguishing
    /// emoji prefix so they're recognizable in the banner / Notification Center;
    /// macOS does not allow swapping the left-side app icon. All other types
    /// render the worktree name unchanged.
    nonisolated static func bannerTitle(worktreeName: String, type: NotificationType) -> String {
        type == .focusRequest ? "🎯 \(worktreeName)" : worktreeName
    }

    /// The banner body. Falls back to a type-appropriate default when no
    /// message was supplied. Mirrors `bannerTitle` as a pure, testable seam
    /// (`postIfEnabled` early-returns unbundled, so the logic can't be tested
    /// through it).
    nonisolated static func bannerBody(message: String?, type: NotificationType) -> String {
        if let msg = message, !msg.isEmpty {
            return msg.count > 200 ? String(msg.prefix(200)) + "…" : msg
        }
        return type == .focusRequest ? "Attention needed." : "Claude has finished responding."
    }

    func postIfEnabled(worktreeID: UUID, message: String?, worktrees: [Worktree],
                       type: NotificationType, terminalID: UUID? = nil) {
        guard enabled, isAvailable else { return }
        requestPermissionIfNeeded()

        let worktreeName = worktrees.first(where: { $0.id == worktreeID })?.displayName
            ?? worktreeID.uuidString

        let truncatedMessage = Self.bannerBody(message: message, type: type)

        let content = UNMutableNotificationContent()
        content.title = Self.bannerTitle(worktreeName: worktreeName, type: type)
        content.body = truncatedMessage
        content.sound = nil
        // The request `identifier` must stay as worktreeID so re-posting
        // collapses banners (one outstanding banner per worktree). Stash the
        // originating terminal in userInfo so the click handler can route to
        // the specific tab.
        if let terminalID {
            content.userInfo = ["terminalID": terminalID.uuidString]
        }

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

    /// Remove delivered banners for the given worktrees from Notification Center.
    /// Safe to call on unbundled executables — guarded by `isAvailable`.
    /// Empty sequences are a no-op.
    func dismissDelivered(worktreeIDs: some Sequence<UUID>) {
        guard isAvailable else { return }
        let identifiers = worktreeIDs.map(\.uuidString)
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Parse a notification request identifier and navigate to the matching worktree.
    /// Factored out of the delegate method so it's testable without faking
    /// `UNNotificationResponse` (which has no public initializer).
    func handleClick(identifier: String) {
        handleClick(identifier: identifier, terminalIDString: nil)
    }

    /// Same as `handleClick(identifier:)` but also routes to a specific
    /// terminal tab when `terminalIDString` is a valid UUID string. Both
    /// parameters are strings to mirror the on-the-wire shapes the
    /// `UNNotificationResponse` exposes (request identifier + userInfo dict).
    func handleClick(identifier: String, terminalIDString: String?) {
        guard let worktreeID = UUID(uuidString: identifier) else {
            logger.error("Banner click identifier is not a UUID: \(identifier, privacy: .public)")
            return
        }
        let terminalID: UUID?
        if let terminalIDString {
            terminalID = UUID(uuidString: terminalIDString)
            if terminalID == nil {
                logger.warning("Banner click userInfo terminalID is not a UUID: \(terminalIDString, privacy: .public)")
            }
        } else {
            terminalID = nil
        }
        handleClick(worktreeID: worktreeID, terminalID: terminalID)
    }

    /// Strongly-typed entry point — used by tests to drive the click path
    /// without faking string parsing.
    func handleClick(worktreeID: UUID, terminalID: UUID?) {
        guard let appState else {
            logger.error("Banner click ignored: appState not configured")
            return
        }
        appState.navigateToWorktree(worktreeID, terminalID: terminalID)
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
        let terminalIDString = response.notification.request.content
            .userInfo["terminalID"] as? String
        // Call the completion handler synchronously to satisfy its
        // non-Sendable isolation, then hop to the main actor for navigation.
        completionHandler()
        Task { @MainActor in
            self.handleClick(identifier: identifier, terminalIDString: terminalIDString)
        }
    }
}
