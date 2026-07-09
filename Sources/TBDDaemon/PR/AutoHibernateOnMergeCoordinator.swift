import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "AutoHibernateOnMerge")

/// Evaluates the effective auto-hibernate-on-merge decision when a worktree's PR
/// merges and parks its idle Claude sessions when armed. Unlike auto-archive,
/// this leaves the worktree alive — it only tears down the sessions' claude
/// processes (window/tab survive), so a later focus wakes them.
///
/// Reached via `MergedTransitionDispatcher`, which enforces the precedence rule
/// (archive supersedes hibernate): this only runs when the worktree was NOT
/// actually archived.
public struct AutoHibernateOnMergeCoordinator: Sendable {
    let db: TBDDatabase
    let hibernation: HibernationCoordinator
    let subscriptions: StateSubscriptionManager

    public init(
        db: TBDDatabase,
        hibernation: HibernationCoordinator,
        subscriptions: StateSubscriptionManager
    ) {
        self.db = db
        self.hibernation = hibernation
        self.subscriptions = subscriptions
    }

    public func handleMergedTransition(worktreeID: UUID, prNumber: Int) async {
        do {
            guard let wt = try await db.worktrees.get(id: worktreeID), wt.status == .active else { return }
            let config = try await db.config.get()
            // NOTE: this deliberately does NOT consult `config.autoHibernateEnabled`
            // — that is the *idle sweep's* master switch. Merge-park is an
            // independent feature armed by the per-worktree tri-state +
            // `config.autoHibernateOnMergeDefault`. (See HibernationGate.decideForMerge.)
            let effective = wt.autoHibernateOnMerge ?? config.autoHibernateOnMergeDefault
            guard effective else { return }

            // The setting is per-WORKTREE; hibernation is per-TERMINAL — fan out.
            let terminals = try await db.terminals.list(worktreeID: worktreeID)
            var parked = 0
            for terminal in terminals {
                let result = await hibernation.hibernateForMerge(terminalID: terminal.id)
                switch result {
                case .ok:
                    parked += 1
                case .alreadyHibernated:
                    logger.debug("merge-park skipped \(terminal.id, privacy: .public): already hibernated")
                case .notFound:
                    logger.debug("merge-park skipped \(terminal.id, privacy: .public): not found")
                case .notEligible(let reason):
                    logger.debug("merge-park skipped \(terminal.id, privacy: .public): \(reason, privacy: .public)")
                }
            }

            guard parked > 0 else {
                logger.debug("auto-hibernate armed for \(worktreeID, privacy: .public) but parked 0 sessions on PR #\(prNumber, privacy: .public) merge")
                return
            }

            // `performHibernate` already broadcast a per-terminal hibernation
            // delta for each parked session, so DON'T broadcast one here — just
            // surface the summary as a non-activating notification.
            let sessionWord = parked == 1 ? "session" : "sessions"
            let notification = try await db.notifications.create(
                worktreeID: worktreeID,
                type: .taskComplete,
                message: "Hibernated \(parked) \(sessionWord) in \(wt.displayName) — PR #\(prNumber) merged",
                terminalID: nil)
            subscriptions.broadcast(delta: .notificationReceived(NotificationDelta(
                notificationID: notification.id, worktreeID: notification.worktreeID,
                type: notification.type, message: notification.message,
                terminalID: notification.terminalID, activate: false)))
            logger.info("auto-hibernated \(parked, privacy: .public) session(s) in \(worktreeID, privacy: .public) on PR #\(prNumber, privacy: .public) merge")
        } catch {
            logger.error("auto-hibernate failed for \(worktreeID, privacy: .public): \(error, privacy: .public)")
        }
    }
}
