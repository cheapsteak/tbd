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
    /// `beginArchiveWorktree` succeeded, or a remote lane's archive went
    /// through `archiveRemoteLane`). Every early return — not active, not
    /// effective, active children, an unwritable record, uncommitted changes
    /// in the folder, or the outer catch — returns `false`. The
    /// `MergedTransitionDispatcher` keys the
    /// archive-supersedes-hibernate precedence off this Bool: an
    /// armed-but-blocked archive returns `false`, so the worktree survives and
    /// its idle sessions are still eligible for merge-park.
    ///
    /// Uncommitted changes are the one refusal the user hears about. The
    /// worktree's folder holds work an archive would delete, so the request
    /// row is confirmed `refused`/`not-eligible` with the refusal sentence and
    /// an attention notification says the worktree was kept and why: the
    /// merged edge that triggered this is not seen again this daemon run, and
    /// without the notification a user expecting the archive would find the
    /// worktree still active with no reason given.
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

            // The uncommitted-changes guard stays on: the user armed a rail,
            // not a decision about files they have not committed, and this
            // archive happens with nobody at the keyboard to ask.
            let worktree: Worktree
            let repo: Repo
            do {
                (worktree, repo) = try await lifecycle.beginArchiveWorktree(worktreeID: worktreeID)
            } catch WorktreeArchiveError.uncommittedChanges(let refusal) {
                await actuationLog.appendOutcome(
                    confirms: actuationID, result: .refused(.notEligible), error: refusal.message)
                logger.notice(
                    "auto-archive declined for \(worktreeID, privacy: .public): \(refusal.message, privacy: .public)")
                await notifyKept(wt, prNumber: prNumber, refusal: refusal)
                return false
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

    /// Persists and broadcasts the notification for a worktree the rail kept
    /// because its folder holds uncommitted changes, or because its status
    /// could not be read. Non-activating, like the archive notification: it
    /// asks for attention without taking focus. The worktree is kept whether
    /// or not this lands, so a failed write is logged and changes nothing.
    private func notifyKept(
        _ wt: Worktree, prNumber: Int, refusal: UncommittedArchiveRefusal
    ) async {
        let message: String
        switch refusal.kind {
        case .dirty:
            message = "Kept \(wt.displayName): PR #\(prNumber) merged, but it has uncommitted changes that archiving would delete."
        case .unverifiable:
            message = "Kept \(wt.displayName): PR #\(prNumber) merged, but TBD could not check it for uncommitted changes."
        }
        do {
            let notification = try await db.notifications.create(
                worktreeID: wt.id,
                type: .attentionNeeded,
                message: message,
                terminalID: nil)
            subscriptions.broadcast(delta: .notificationReceived(NotificationDelta(
                notificationID: notification.id, worktreeID: notification.worktreeID,
                type: notification.type, message: notification.message,
                terminalID: notification.terminalID, activate: false)))
        } catch {
            logger.error(
                "auto-archive kept \(wt.id, privacy: .public) but could not record a notification: \(error, privacy: .public)")
        }
    }

    /// The remote lane's half of the rail. Same routing, same guards and the
    /// same record shape as the manual `worktree.archive` remote branch — the
    /// only differences are this rail's own actuation actor and its
    /// notification, both of which it already writes for a local worktree.
    ///
    /// A refusal from the archive decision — no declared `archive` on a lane
    /// that is not `gone`, the stale inventory, an agent still working, a
    /// provider-reported dirty checkout — returns `false` and records the
    /// decline: a request row under the rail's daemon actor, confirmed
    /// `refused` with the reason `not-eligible` and the refusal sentence. The
    /// merged edge that triggered it is not seen again this daemon run, so
    /// that row is how a lane left active after its PR merged is traced to the
    /// refusal that kept it, and a refused outcome claims no act. Logged at
    /// `.notice`, not surfaced: this is a background rail, and declining is
    /// its ordinary behavior.
    ///
    /// With no provider manager (remote backends were off when the daemon
    /// started) there is nothing to ask, so the rail makes
    /// no decision and writes no row, exactly as for a lane it is not armed
    /// for.
    private func archiveRemoteLane(_ wt: Worktree, prNumber: Int) async -> Bool {
        guard let remoteManager else {
            logger.debug("auto-archive skipped (no provider manager): \(wt.id, privacy: .public)")
            return false
        }
        let lanes = RemoteLaneLifecycle(
            db: db, subscriptions: subscriptions, manager: remoteManager)
        let step: RemoteLaneLifecycle.ArchiveStep
        do {
            switch try await lanes.archiveDecision(for: wt, force: false) {
            case .refused(let message), .guarded(let message):
                logger.notice(
                    "auto-archive declined for \(wt.id, privacy: .public): \(message, privacy: .public)")
                await recordDecline(of: wt, message: message)
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
        let actuationID: String
        do {
            actuationID = try await actuationLog.appendRequest(remoteDisposeRequest(for: wt))
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

    /// The request row this rail writes for a remote lane, whether it then
    /// archives the lane or declines it: no RPC carried it, so it names no
    /// method, only the rail's actor and the worktree.
    private func remoteDisposeRequest(for wt: Worktree) -> ActuationRow {
        var request = ActuationRow(
            actor: .daemon(rail: ActuationRail.autoArchiveOnMerge), kind: .dispose)
        request.target = ActuationTarget(worktree: wt.id.uuidString)
        return request
    }

    /// Records a declined remote archive as its request row confirmed
    /// `refused`/`not-eligible`. The lane is declined either way, so an
    /// unwritable record changes nothing about the outcome: it is logged and
    /// the rail moves on.
    private func recordDecline(of wt: Worktree, message: String) async {
        do {
            let actuationID = try await actuationLog.appendRequest(remoteDisposeRequest(for: wt))
            await actuationLog.appendOutcome(
                confirms: actuationID, result: .refused(.notEligible), error: message)
        } catch {
            logger.warning("auto-archive decline not recorded (record unwritable): \(wt.id, privacy: .public): \(error, privacy: .public)")
        }
    }
}
