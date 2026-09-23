import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "nightwatch")

/// The boot step that re-applies the persisted watch mode to the
/// `DaywatchRunner`, with the one-time reconcile for the combination
/// `NightwatchHolderGate` forbids.
///
/// A persisted watch mode alongside the effective pty-holder flag is reachable
/// only by an install that combined the two on a daemon older than the gate.
/// The two switch refusals make it unre-enterable, so the reconcile runs once
/// per such install and is otherwise a no-op. It is the one write to the watch
/// mode not behind a user gesture, because at boot none is available.
///
/// Spec: docs/specs/2026-09-22-nightwatch-deprecation-holder-gate-design.md,
/// "Enforcement point 3: boot reconcile".
enum NightwatchHolderBootReconcile {
    /// Returns the mode that was applied to the runner, or nil when the runner was not started.
    @discardableResult
    static func run(
        db: TBDDatabase,
        subscriptions: StateSubscriptionManager,
        applyMode: (NightwatchMode) async -> Void
    ) async throws -> NightwatchMode? {
        let config = try await db.config.get()
        guard NightwatchHolderGate.bootMustTurnModeOff(config) else {
            await applyMode(config.nightwatchMode)
            return config.nightwatchMode
        }

        try await db.config.setNightwatchMode(.off)
        logger.notice("Turned \(config.nightwatchMode.rawValue, privacy: .public) mode off at boot: \(NightwatchHolderGate.modeRefusal, privacy: .public)")

        // Notifications are keyed by worktree — there is no worktree-less
        // shape — so the refusal lands on the Watch Desk scratch worktree when
        // one exists, else on the first local worktree, else nowhere.
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

        subscriptions.broadcast(delta: .modelProfilesChanged)
        return nil
    }
}
