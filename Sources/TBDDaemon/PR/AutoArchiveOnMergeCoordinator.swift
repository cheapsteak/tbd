import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "AutoArchiveOnMerge")

/// Evaluates the effective auto-archive decision when a worktree's PR merges and
/// archives it when armed. Wired to `PRStatusManager.onMergedTransition`.
public struct AutoArchiveOnMergeCoordinator: Sendable {
    let db: TBDDatabase
    let lifecycle: WorktreeLifecycle
    let subscriptions: StateSubscriptionManager

    public init(db: TBDDatabase, lifecycle: WorktreeLifecycle, subscriptions: StateSubscriptionManager) {
        self.db = db
        self.lifecycle = lifecycle
        self.subscriptions = subscriptions
    }

    public func handleMergedTransition(worktreeID: UUID, prNumber: Int) async {
        do {
            guard let wt = try await db.worktrees.get(id: worktreeID), wt.status == .active else { return }
            let config = try await db.config.get()
            let effective = wt.autoArchiveOnMerge ?? config.autoArchiveOnMergeDefault
            guard effective else { return }

            // Worktrees with active children are not auto-archivable. Narrow the
            // catch to the children guard so DB errors fall through to the outer
            // catch and are logged at .error rather than silently swallowed.
            do {
                try await db.worktrees.assertArchivable(id: worktreeID)
            } catch WorktreeArchiveError.hasActiveChildren {
                logger.info("auto-archive skipped (active children): \(worktreeID, privacy: .public)")
                return
            }

            let (worktree, repo) = try await lifecycle.beginArchiveWorktree(worktreeID: worktreeID)
            subscriptions.broadcast(delta: .worktreeArchived(WorktreeIDDelta(worktreeID: worktreeID)))

            // Surface it: persist + broadcast a notification (non-activating).
            let notification = try await db.notifications.create(
                worktreeID: worktreeID,
                type: .taskComplete,
                message: "Archived \(worktree.displayName) — PR #\(prNumber) merged",
                terminalID: nil)
            subscriptions.broadcast(delta: .notificationReceived(NotificationDelta(
                notificationID: notification.id, worktreeID: notification.worktreeID,
                type: notification.type, message: notification.message,
                terminalID: notification.terminalID, activate: false)))

            // Slow phase (hook + git worktree remove) in background, like the archive RPC handler.
            let lifecycle = self.lifecycle
            Task.detached {
                await lifecycle.completeArchiveWorktree(worktree: worktree, repo: repo, force: false)
            }
            logger.info("auto-archived \(worktreeID, privacy: .public) on PR #\(prNumber, privacy: .public) merge")
        } catch {
            logger.error("auto-archive failed for \(worktreeID, privacy: .public): \(error, privacy: .public)")
        }
    }
}
