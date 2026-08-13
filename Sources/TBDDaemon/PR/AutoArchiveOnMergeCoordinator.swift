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
    /// The daemon's actuation record. This is a daemon-internal rail — no RPC
    /// carried it — so it writes its own row, with no `method` and the
    /// rail-named actor. Deliberately NOT logged inside `beginArchiveWorktree`:
    /// the `worktree.archive` handler calls that same method after writing its
    /// own row, and a row there would double-count every manual archive.
    let actuationLog: ActuationLog

    public init(
        db: TBDDatabase,
        lifecycle: WorktreeLifecycle,
        subscriptions: StateSubscriptionManager,
        actuationLog: ActuationLog
    ) {
        self.db = db
        self.lifecycle = lifecycle
        self.subscriptions = subscriptions
        self.actuationLog = actuationLog
    }

    /// Returns `true` ONLY when it actually began archiving the worktree (i.e.
    /// `beginArchiveWorktree` succeeded). Every early return — not active,
    /// remote, not effective, active children, or the outer catch — returns
    /// `false`. The
    /// `MergedTransitionDispatcher` keys the archive-supersedes-hibernate
    /// precedence off this Bool: an armed-but-blocked archive returns `false`, so
    /// the worktree survives and its idle sessions are still eligible for merge-park.
    @discardableResult
    public func handleMergedTransition(worktreeID: UUID, prNumber: Int) async -> Bool {
        do {
            guard let wt = try await db.worktrees.get(id: worktreeID), wt.status == .active else { return false }

            // A remote lane is not auto-archivable, and is refused here rather
            // than allowed to fail downstream. Archiving a remote worktree
            // would mean stopping the provider's session — deliberately
            // unimplemented, not an oversight — so `beginArchiveWorktree`
            // resolves through `getLocal` and throws for a remote row. Reaching
            // it would mean the rail had already written a `.dispose` request
            // for an act it structurally cannot perform, and rewritten it on
            // every merged transition observed for that lane. The record may
            // only claim acts that were attempted, so the gate belongs above
            // the row, not in the catch below it.
            guard wt.location.isLocal else {
                logger.debug("auto-archive skipped (remote lane): \(worktreeID, privacy: .public)")
                return false
            }

            let config = try await db.config.get()
            let effective = wt.autoArchiveOnMerge ?? config.autoArchiveOnMergeDefault
            guard effective else { return false }

            // Worktrees with active children are not auto-archivable. Narrow the
            // catch to the children guard so DB errors fall through to the outer
            // catch and are logged at .error rather than silently swallowed.
            do {
                try await db.worktrees.assertArchivable(id: worktreeID)
            } catch WorktreeArchiveError.hasActiveChildren {
                logger.info("auto-archive skipped (active children): \(worktreeID, privacy: .public)")
                return false
            }

            // The rail's own row, written at its act moment — after the gates
            // above, at the point this rail is actually about to tear a
            // worktree's sessions down. Fail-closed, as everywhere else: an
            // unrecordable archive does not happen, and the worktree survives
            // for the next merged-transition to retry. The writer already
            // logged the failure at `.fault`.
            var row = ActuationRow(
                actor: .daemon(rail: ActuationRail.autoArchiveOnMerge), kind: .dispose)
            row.target = ActuationTarget(worktree: worktreeID.uuidString)
            let actuationID: String
            do {
                actuationID = try await actuationLog.appendRequest(row)
            } catch {
                logger.warning("auto-archive skipped (record unwritable): \(worktreeID, privacy: .public): \(error, privacy: .public)")
                return false
            }

            let worktree: Worktree
            let repo: Repo
            do {
                (worktree, repo) = try await lifecycle.beginArchiveWorktree(worktreeID: worktreeID)
            } catch {
                await actuationLog.appendOutcome(
                    confirms: actuationID, result: .transportFailed, error: "\(error)")
                throw error
            }
            await actuationLog.appendOutcome(confirms: actuationID, result: .dispatched)
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
            return true
        } catch {
            logger.error("auto-archive failed for \(worktreeID, privacy: .public): \(error, privacy: .public)")
            return false
        }
    }
}
