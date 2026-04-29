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

        let activeMatch = appState.worktrees.values
            .flatMap { $0 }
            .contains(where: { $0.id == worktreeID })
        if activeMatch {
            appState.navigateToActiveWorktree(worktreeID)
            return
        }

        // Active miss. Archived fallback is wired up in Task 4 of the deep-link
        // implementation plan; for now, log and stop.
        logger.warning("Deep link references unknown worktree \(worktreeID, privacy: .public)")
    }
}
