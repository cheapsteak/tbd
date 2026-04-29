import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "deeplink")

/// Parses `tbd://` URLs and dispatches navigation against an `AppState`.
/// Never throws, never surfaces UI errors — invalid or stale links are
/// logged and silently ignored.
enum DeepLinkHandler {
    @MainActor
    static func handle(_ url: URL, appState: AppState) {
        guard let worktreeID = DeepLink.parseOpenURL(url) else {
            logger.warning("Ignoring malformed deep link: \(url.absoluteString, privacy: .public)")
            return
        }
        appState.navigateToWorktree(worktreeID)
    }
}
