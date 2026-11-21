import Foundation
import UserNotifications
import SwiftUI
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "MacNotificationManager")

@MainActor
final class MacNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    @AppStorage("enableNotifications") private var enabled: Bool = true

    /// Supplies the sound attached to each banner from the user's settings.
    private let soundPlayer = NotificationSoundPlayer()

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
        // The mock harness runs a bundled second instance; a permission prompt
        // would intrude on staged screenshots. Skip it entirely in mock mode.
        if MockMode.isActive() { return }
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
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
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

    /// Whether `postIfEnabled` should proceed to post a banner. Pure seam so the
    /// gating logic — including mock-mode suppression (the mock instance must never
    /// post notifications, per the harness design) — is testable without a bundle,
    /// since `postIfEnabled` itself early-returns on unbundled executables.
    nonisolated static func shouldPost(enabled: Bool, isAvailable: Bool, mockActive: Bool) -> Bool {
        enabled && isAvailable && !mockActive
    }

    /// `worktreeName` is the caller-resolved display name (nil when the
    /// worktree is unknown — the banner falls back to the raw UUID string).
    func postIfEnabled(worktreeID: UUID, message: String?, worktreeName: String?,
                       type: NotificationType, terminalID: UUID? = nil) {
        guard Self.shouldPost(enabled: enabled, isAvailable: isAvailable, mockActive: MockMode.isActive()) else { return }
        requestPermissionIfNeeded()

        let worktreeName = worktreeName ?? worktreeID.uuidString

        let truncatedMessage = Self.bannerBody(message: message, type: type)

        let content = UNMutableNotificationContent()
        content.title = Self.bannerTitle(worktreeName: worktreeName, type: type)
        content.body = truncatedMessage
        // The center plays the sound, so Focus and Do Not Disturb silence it
        // along with the banner. Nothing plays it directly.
        content.sound = soundPlayer.notificationSound(for: type)
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

    /// The prefix every remote-session banner's request identifier starts
    /// with. A click whose identifier starts with it is routed to the remote
    /// session, never parsed as a worktree UUID.
    nonisolated static let remoteIdentifierPrefix = "remote:"

    /// The userInfo keys a remote-session banner carries its provider name
    /// and session ID under, so the click handler reads them whole instead of
    /// splitting the identifier.
    nonisolated static let remoteProviderUserInfoKey = "remoteProvider"
    nonisolated static let remoteSessionIDUserInfoKey = "remoteSessionID"

    /// A remote session's banner request identifier,
    /// `remote:<provider>:<sessionID>`. One identifier per session, so a
    /// re-post replaces that session's outstanding banner rather than
    /// stacking a second one.
    nonisolated static func remoteBannerIdentifier(provider: String, sessionID: String) -> String {
        "\(remoteIdentifierPrefix)\(provider):\(sessionID)"
    }

    /// The userInfo `postRemoteAttention` attaches to a remote session's
    /// banner. Pure seam, as `bannerTitle` is, because the post itself
    /// returns early unbundled.
    nonisolated static func remoteBannerUserInfo(provider: String, sessionID: String) -> [String: String] {
        [remoteProviderUserInfoKey: provider, remoteSessionIDUserInfoKey: sessionID]
    }

    /// Post a banner for a remote session crossing a notify-worthy agent-state
    /// edge (→ waiting_input or → exited). Remote sessions have no worktree,
    /// so this bypasses `postIfEnabled`'s worktree-keyed identifier: the
    /// request is keyed by `remoteBannerIdentifier` and carries the provider
    /// and session ID in userInfo (`remoteBannerUserInfo`). A click on it
    /// opens that session (`handleClick(identifier:terminalIDString:remoteProvider:remoteSessionID:)`).
    func postRemoteAttention(provider: String, sessionID: String, title: String, body: String) {
        guard Self.shouldPost(enabled: enabled, isAvailable: isAvailable, mockActive: MockMode.isActive()) else { return }
        requestPermissionIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        content.userInfo = Self.remoteBannerUserInfo(provider: provider, sessionID: sessionID)

        let request = UNNotificationRequest(
            identifier: Self.remoteBannerIdentifier(provider: provider, sessionID: sessionID),
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

    /// Show banners, and play their sound, even when TBD is the frontmost app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        handler([.banner, .sound])
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

    /// Parse a notification request identifier and navigate to the matching
    /// worktree or remote session. Factored out of the delegate method so
    /// it's testable without faking `UNNotificationResponse` (which has no
    /// public initializer).
    func handleClick(identifier: String) {
        handleClick(identifier: identifier, terminalIDString: nil)
    }

    /// Same as `handleClick(identifier:)` but also routes to a specific
    /// terminal tab when `terminalIDString` is a valid UUID string. Every
    /// parameter is a string to mirror the on-the-wire shapes the
    /// `UNNotificationResponse` exposes (request identifier + userInfo dict).
    ///
    /// An identifier starting with `remoteIdentifierPrefix` is a remote
    /// session's banner and goes to `handleRemoteClick`, with the provider
    /// and session ID its userInfo carried (nil when absent). Any other
    /// identifier is a worktree UUID.
    func handleClick(
        identifier: String, terminalIDString: String?,
        remoteProvider: String? = nil, remoteSessionID: String? = nil
    ) {
        if identifier.hasPrefix(Self.remoteIdentifierPrefix) {
            handleRemoteClick(identifier: identifier, provider: remoteProvider, sessionID: remoteSessionID)
            return
        }
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

    /// A remote session's banner click: resolve the session it names
    /// (`remoteClickTarget`) and open it (`AppState.navigateToRemoteSession`).
    /// An identifier that names no session is logged and ignored.
    func handleRemoteClick(identifier: String, provider: String?, sessionID: String?) {
        guard let target = Self.remoteClickTarget(
            identifier: identifier, provider: provider, sessionID: sessionID)
        else {
            logger.error("Remote banner click names no session: \(identifier, privacy: .public)")
            return
        }
        guard let appState else {
            logger.error("Banner click ignored: appState not configured")
            return
        }
        appState.navigateToRemoteSession(provider: target.provider, sessionID: target.sessionID)
    }

    /// The session a remote banner names: the provider and session ID from
    /// its userInfo when both are present and non-empty, otherwise parsed from
    /// the identifier. The identifier is the only source for a banner posted
    /// without that userInfo, which Notification Center can still hold.
    ///
    /// The parse drops `remoteIdentifierPrefix` and splits at the FIRST `:`.
    /// A session ID is an opaque provider string and may contain `:`, so
    /// everything after that colon is the session ID. A provider name may
    /// contain `:` too — the registry (`RemoteProviderRegistry.loadEntries`)
    /// requires only a non-empty name — and the identifier alone cannot tell
    /// that colon from the separator, so such a name parses wrong here. The
    /// userInfo keys exist so a banner never depends on this parse.
    ///
    /// Nil when the identifier lacks the prefix or yields an empty provider
    /// or session ID.
    nonisolated static func remoteClickTarget(
        identifier: String, provider: String?, sessionID: String?
    ) -> RemoteSessionSelection? {
        if let provider, let sessionID, !provider.isEmpty, !sessionID.isEmpty {
            return RemoteSessionSelection(provider: provider, sessionID: sessionID)
        }
        guard identifier.hasPrefix(remoteIdentifierPrefix) else { return nil }
        let rest = identifier.dropFirst(remoteIdentifierPrefix.count)
        guard let separator = rest.firstIndex(of: ":") else { return nil }
        let parsedProvider = String(rest[..<separator])
        let parsedSessionID = String(rest[rest.index(after: separator)...])
        guard !parsedProvider.isEmpty, !parsedSessionID.isEmpty else { return nil }
        return RemoteSessionSelection(provider: parsedProvider, sessionID: parsedSessionID)
    }

    /// Banner click → focus the worktree or remote session the notification
    /// was about. `nonisolated` to satisfy the protocol's isolation
    /// requirement, matching `willPresent` above. Hops back to the main actor
    /// to invoke `handleClick`.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Read everything the click needs as Strings here: neither the
        // response nor its userInfo is Sendable, so neither may cross the
        // hop to the main actor below.
        let identifier = response.notification.request.identifier
        let userInfo = response.notification.request.content.userInfo
        let terminalIDString = userInfo["terminalID"] as? String
        let remoteProvider = userInfo[Self.remoteProviderUserInfoKey] as? String
        let remoteSessionID = userInfo[Self.remoteSessionIDUserInfoKey] as? String
        // Call the completion handler synchronously to satisfy its
        // non-Sendable isolation, then hop to the main actor for navigation.
        completionHandler()
        Task { @MainActor in
            self.handleClick(
                identifier: identifier, terminalIDString: terminalIDString,
                remoteProvider: remoteProvider, remoteSessionID: remoteSessionID)
        }
    }
}
