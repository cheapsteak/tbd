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

    /// UNUserNotificationCenter crashes unbundled executables (no CFBundleIdentifier).
    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    func requestPermissionIfNeeded() {
        guard isAvailable, !hasRequestedPermission else { return }
        hasRequestedPermission = true

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                logger.error("Permission error: \(error)")
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
}
