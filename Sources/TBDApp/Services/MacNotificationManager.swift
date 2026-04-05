import Foundation
import UserNotifications
import SwiftUI
import TBDShared

@MainActor
final class MacNotificationManager {
    @AppStorage("enableNotifications") private var enabled: Bool = true

    private var hasRequestedPermission = false

    func requestPermissionIfNeeded() {
        guard !hasRequestedPermission else { return }
        hasRequestedPermission = true

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                print("[MacNotificationManager] Permission error: \(error)")
            }
        }
    }

    func postIfEnabled(worktreeID: UUID, message: String?, worktrees: [Worktree]) {
        guard enabled else { return }
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
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[MacNotificationManager] Post error: \(error)")
            }
        }
    }
}
