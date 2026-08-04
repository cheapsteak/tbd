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

    /// Returns `true` ONLY when it actually began archiving the worktree (i.e.
    /// `beginArchiveWorktree` succeeded). Every early return — not active, not
    /// effective, active children, or the outer catch — returns `false`. The
    /// `MergedTransitionDispatcher` keys the archive-supersedes-hibernate
    /// precedence off this Bool: an armed-but-blocked archive returns `false`, so
    /// the worktree survives and its idle sessions are still eligible for merge-park.
    @discardableResult
    public func handleMergedTransition(worktreeID: UUID, prNumber: Int) async -> Bool {
        var activeWorktreeDisplayName: String?
        do {
            guard let wt = try await db.worktrees.get(id: worktreeID), wt.status == .active else { return false }
            let config = try await db.config.get()
            let effective = wt.autoArchiveOnMerge ?? config.autoArchiveOnMergeDefault
            guard effective else { return false }
            activeWorktreeDisplayName = wt.displayName

            // Worktrees with active children are not auto-archivable. Narrow the
            // catch to the children guard so DB errors fall through to the outer
            // catch and are logged at .error rather than silently swallowed.
            do {
                try await db.worktrees.assertArchivable(id: worktreeID)
            } catch WorktreeArchiveError.hasActiveChildren {
                logger.info("auto-archive skipped (active children): \(worktreeID, privacy: .public)")
                return false
            }

            // A merge event proves the PR merged, not that this worktree's
            // current HEAD has no later local commits. Both archive checks
            // must reverify the current HEAD against remote-tracking refs.
            let (worktree, repo) = try await lifecycle.beginArchiveWorktree(worktreeID: worktreeID)
            try await lifecycle.completeArchiveWorktree(
                worktree: worktree,
                repo: repo
            )
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

            logger.info("auto-archived \(worktreeID, privacy: .public) on PR #\(prNumber, privacy: .public) merge")
            return true
        } catch {
            logger.error("auto-archive failed for \(worktreeID, privacy: .public): \(error, privacy: .public)")
            if let displayName = activeWorktreeDisplayName {
                do {
                    let detail = String(describing: error)
                    let boundedDetail = String(detail.prefix(500))
                    let notification = try await db.notifications.create(
                        worktreeID: worktreeID,
                        type: .error,
                        message: "Auto-archive failed for \(displayName): \(boundedDetail)",
                        terminalID: nil
                    )
                    subscriptions.broadcast(delta: .notificationReceived(NotificationDelta(
                        notificationID: notification.id,
                        worktreeID: notification.worktreeID,
                        type: notification.type,
                        message: notification.message,
                        terminalID: notification.terminalID,
                        activate: false
                    )))
                } catch {
                    logger.error(
                        "failed to surface auto-archive error for \(worktreeID, privacy: .public): \(error, privacy: .public)"
                    )
                }
            }
            return false
        }
    }
}
