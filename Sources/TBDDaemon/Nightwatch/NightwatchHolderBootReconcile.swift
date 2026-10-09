import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "nightwatch")

/// The boot step that re-applies the persisted watch mode to the
/// `DaywatchRunner`, with the one-time reconcile for the combination
/// `NightwatchHolderGate` forbids.
///
/// Two kinds of install reach a persisted watch mode while the holder hazard
/// is live: one that combined the two on a daemon older than the gate, and one
/// that left a watch mode on and never touched the holder toggle, whose
/// effective flag reads on through the shipped default. The two switch
/// refusals make the pair unre-enterable by gesture, and the mode write below
/// means every later boot reads `.off` — so this fires at most once per install
/// and is otherwise a no-op. It is the one write to the watch mode not behind a
/// user gesture, because at boot none is available.
///
/// `holderSupported` is the second half of the hazard and is not optional
/// here: a daemon that cannot start a holder spawns no holder-backed session,
/// so it must leave a persisted watch mode running rather than take it away.
///
/// The mode write and the `.modelProfilesChanged` broadcast that reflects it
/// are the durable part of this reconcile and always happen together. The
/// worktree lookup and notification are best-effort: telling the user why
/// their mode changed matters, but it must never leave the mode written and
/// the UI unnotified just because a notification could not be created.
///
/// Spec: docs/specs/2026-09-22-nightwatch-deprecation-holder-gate-design.md,
/// "Enforcement point 3: boot reconcile".
enum NightwatchHolderBootReconcile {
    /// Returns the mode that was applied to the runner, or nil when the runner was not started.
    @discardableResult
    static func run(
        db: TBDDatabase,
        subscriptions: StateSubscriptionManager,
        holderSupported: Bool,
        applyMode: (NightwatchMode) async -> Void
    ) async throws -> NightwatchMode? {
        let config = try await db.config.get()
        guard NightwatchHolderGate.bootMustTurnModeOff(
            config, holderSupported: holderSupported) else {
            await applyMode(config.nightwatchMode)
            return config.nightwatchMode
        }

        try await db.config.setNightwatchMode(.off)
        logger.notice("Turned \(config.nightwatchMode.rawValue, privacy: .public) mode off at boot: \(NightwatchHolderGate.modeRefusal, privacy: .public)")
        subscriptions.broadcast(delta: .modelProfilesChanged)

        // Notifications are keyed by worktree — there is no worktree-less
        // shape — so the refusal lands on the Watch Desk scratch worktree when
        // one exists, else on the first local worktree, else nowhere. This leg
        // is best-effort: the mode write and its broadcast above already
        // happened, so a failure here is logged, not rethrown.
        do {
            let worktrees = try await db.worktrees.listLocal(excludeArchived: true)
            let target = worktrees.first(where: {
                $0.displayName == NightwatchDeskPrompts.deskDisplayName && $0.isScratch
            }) ?? worktrees.first
            if let target {
                let notification = try await db.notifications.create(
                    worktreeID: target.id, type: .attentionNeeded,
                    message: NightwatchHolderGate.modeRefusal)
                subscriptions.broadcast(delta: .notificationReceived(NotificationDelta(
                    notificationID: notification.id, worktreeID: notification.worktreeID,
                    type: notification.type, message: notification.message,
                    terminalID: notification.terminalID)))
            } else {
                logger.notice("No local worktree to carry the boot-reconcile notification; skipped it")
            }
        } catch {
            logger.error("Failed to deliver the boot-reconcile notification: \(error, privacy: .public)")
        }

        return nil
    }
}
