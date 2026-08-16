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
    /// The remote-backends actor, when the subsystem is on. `nil` when the
    /// flag was off at boot (`Daemon.swift` only constructs it then) and in
    /// tests that have no remote lanes — in which case the rail simply
    /// declines a remote lane, as it did before it had a remote path at all.
    let remoteManager: RemoteProviderManager?

    public init(
        db: TBDDatabase,
        lifecycle: WorktreeLifecycle,
        subscriptions: StateSubscriptionManager,
        actuationLog: ActuationLog,
        remoteManager: RemoteProviderManager? = nil
    ) {
        self.db = db
        self.lifecycle = lifecycle
        self.subscriptions = subscriptions
        self.actuationLog = actuationLog
        self.remoteManager = remoteManager
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

            // A remote lane retires down the provider path instead — the same
            // act on the same code as a manual archive, under the opt-in this
            // rail already has. A second switch would gate a switch, so there
            // is no separate flag: the rail is off by default, per-worktree
            // overridable, and armed by a deliberate gesture, and it declines
            // by itself when the provider declares no `archive`
            // (`docs/specs/2026-08-16-remote-lane-archive-design.md`
            // §"Auto-archive on merge").
            if !wt.location.isLocal {
                return await archiveRemoteLane(wt, prNumber: prNumber)
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

    /// The remote lane's half of the rail. Same routing, same guards and the
    /// same record shape as the manual `worktree.archive` remote branch — the
    /// only differences are this rail's own actuation actor and its
    /// notification, both of which it already writes for a local worktree.
    ///
    /// A refusal — no manager, no declared `archive` on a lane that is not
    /// `gone`, an agent still working, a provider-reported dirty checkout —
    /// returns `false` and writes **no** actuation row. Nothing was attempted,
    /// and a background rail that rewrote a `.dispose` request on every merged
    /// transition it observed for an unretireable lane would fill the record
    /// with acts that never happened. Logged at debug, not surfaced: this is a
    /// background rail, and declining is its ordinary behavior.
    private func archiveRemoteLane(_ wt: Worktree, prNumber: Int) async -> Bool {
        guard let remoteManager else {
            logger.debug("auto-archive skipped (remote backends off): \(wt.id, privacy: .public)")
            return false
        }
        let lanes = RemoteLaneLifecycle(
            db: db, subscriptions: subscriptions, manager: remoteManager)
        let step: RemoteLaneLifecycle.ArchiveStep
        do {
            switch try await lanes.archiveDecision(for: wt, force: false) {
            case .refused(let message):
                logger.debug(
                    "auto-archive skipped for \(wt.id, privacy: .public): \(message, privacy: .public)")
                return false
            case .proceed(let decided):
                step = decided
            }
        } catch {
            logger.error(
                "auto-archive could not route \(wt.id, privacy: .public): \(error, privacy: .public)")
            return false
        }

        // Fail-closed exactly as the local path is: an unrecordable archive
        // does not happen, and the worktree survives for the next merged
        // transition to retry.
        var request = ActuationRow(
            actor: .daemon(rail: ActuationRail.autoArchiveOnMerge), kind: .dispose)
        request.target = ActuationTarget(worktree: wt.id.uuidString)
        let actuationID: String
        do {
            actuationID = try await actuationLog.appendRequest(request)
        } catch {
            logger.warning("auto-archive skipped (record unwritable): \(wt.id, privacy: .public): \(error, privacy: .public)")
            return false
        }

        do {
            if let failure = try await lanes.performArchive(step, worktree: wt) {
                await actuationLog.appendOutcome(
                    confirms: actuationID, result: .transportFailed, error: failure)
                logger.error(
                    "auto-archive failed for \(wt.id, privacy: .public): \(failure, privacy: .public)")
                return false
            }
        } catch {
            await actuationLog.appendOutcome(
                confirms: actuationID, result: .transportFailed, error: "\(error)")
            logger.error("auto-archive failed for \(wt.id, privacy: .public): \(error, privacy: .public)")
            return false
        }
        await actuationLog.appendOutcome(confirms: actuationID, result: .dispatched)

        // Same notification the local path creates: a worktree retired without
        // the user asking at that moment has to say why.
        do {
            let notification = try await db.notifications.create(
                worktreeID: wt.id,
                type: .taskComplete,
                message: "Archived \(wt.displayName) — PR #\(prNumber) merged",
                terminalID: nil)
            subscriptions.broadcast(delta: .notificationReceived(NotificationDelta(
                notificationID: notification.id, worktreeID: notification.worktreeID,
                type: notification.type, message: notification.message,
                terminalID: notification.terminalID, activate: false)))
        } catch {
            logger.error(
                "auto-archived \(wt.id, privacy: .public) but could not record a notification: \(error, privacy: .public)")
        }
        logger.info("auto-archived remote lane \(wt.id, privacy: .public) on PR #\(prNumber, privacy: .public) merge")
        return true
    }
}
