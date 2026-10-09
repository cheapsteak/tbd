import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "modelProfileResolver")

/// Tells the person, once, when a balanced pick skips an account whose usage
/// reading is stale (design 2026-09-05 §6.1).
///
/// A candidate skipped as `noFreshReading` is otherwise pool-eligible — the
/// picker assigns that verdict only after the kind, credential and opt-out
/// rules have passed — yet balancing cannot see it. A reading that stays stale
/// usually means a lapsed login or a failing poll, which only the person can
/// fix, so the skip is surfaced as one `.attentionNeeded` notification on the
/// spawning worktree.
///
/// An in-memory latch keyed by profile holds it to once. The latch clears when
/// a balanced pick next sees that profile with a fresh reading (its verdict is
/// `.eligible` or `.exhausted`, both of which the picker reaches only past the
/// freshness rule), so a relapse notifies again. A daemon restart clears it
/// too, costing at most one repeat notification.
///
/// Only balanced picks feed it: the resolver calls `observe` from its balanced
/// branch alone, so the rate-limit suggestion and `balance: false` resumes
/// never notify. There is one instance per daemon, built in `Daemon.swift`
/// and shared by every copy of the resolver.
public actor StaleAccountAlerts {
    /// Posts one notification on a worktree. Production wiring is
    /// `StaleAccountAlerts.notifier(db:subscriptions:)`; tests inject a recorder.
    public typealias Notify = @Sendable (_ worktreeID: UUID, _ message: String) async throws -> Void

    private var latched: Set<UUID> = []
    private let notify: Notify

    public init(notify: @escaping Notify) {
        self.notify = notify
    }

    /// Feed one balanced pick's outcome.
    ///
    /// - Parameters:
    ///   - candidates: The candidates the picker judged.
    ///   - decision: Its decision, whose verdicts decide stale and fresh.
    ///   - worktreeID: The spawning worktree. Nil notifies nobody and leaves
    ///     stale profiles unlatched, so the next spawn that has a worktree
    ///     still tells the person.
    ///   - now: The time the pick judged staleness against.
    ///   - profileName: Looks up the display name for the message.
    public func observe(
        candidates: [ProfilePoolCandidate],
        decision: ProfilePoolDecision,
        worktreeID: UUID?,
        now: Date,
        profileName: @Sendable (UUID) async -> String?
    ) async {
        // Every latch change happens here, before any suspension, so two
        // concurrent picks that both skip the same profile cannot both claim it.
        let toAlert = claim(candidates: candidates, decision: decision, notifying: worktreeID != nil)
        guard let worktreeID else { return }
        for candidate in toAlert {
            let name = await profileName(candidate.profileID)
                ?? String(candidate.profileID.uuidString.prefix(8))
            let message = Self.message(profileName: name, snapshot: candidate.snapshot, now: now)
            do {
                try await notify(worktreeID, message)
                logger.info("stale account \(candidate.profileID, privacy: .public) surfaced on worktree \(worktreeID, privacy: .public)")
            } catch {
                // Unlatch so a later pick retries; never fail the spawn.
                latched.remove(candidate.profileID)
                logger.error("stale account notification failed for \(candidate.profileID, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    /// Whether a profile is currently latched. For tests.
    public func isLatched(_ profileID: UUID) -> Bool {
        latched.contains(profileID)
    }

    /// Clear latches for fresh readings and latch (returning) the stale
    /// profiles not yet latched. Latches nothing when nobody will be told.
    private func claim(
        candidates: [ProfilePoolCandidate],
        decision: ProfilePoolDecision,
        notifying: Bool
    ) -> [ProfilePoolCandidate] {
        var toAlert: [ProfilePoolCandidate] = []
        for candidate in candidates {
            guard let verdict = decision.verdicts[candidate.profileID] else { continue }
            switch verdict {
            case .eligible, .exhausted:
                latched.remove(candidate.profileID)
            case .noFreshReading:
                guard notifying, !latched.contains(candidate.profileID) else { continue }
                latched.insert(candidate.profileID)
                toAlert.append(candidate)
            case .wrongKind, .noCredential, .optedOut, .sameAccount:
                continue
            }
        }
        return toAlert
    }

    /// The notification text: the reading's age in whole minutes (floored),
    /// or "no usage reading yet" when no fetch has ever succeeded.
    public static func message(
        profileName: String,
        snapshot: ProfileUsageSnapshot?,
        now: Date
    ) -> String {
        guard let fetchedAt = snapshot?.fetchedAt else {
            return "Usage for \(profileName) has no usage reading yet — balancing is skipping it; check its login"
        }
        let minutes = max(0, Int((now.timeIntervalSince(fetchedAt) / 60).rounded(.down)))
        return "Usage for \(profileName) hasn't refreshed in \(minutes) min — balancing is skipping it; check its login"
    }

    /// The production `Notify`: persists an `.attentionNeeded` row on the
    /// worktree and broadcasts its delta, the same shape the rate-limit
    /// handler's notifications take.
    public static func notifier(
        db: TBDDatabase,
        subscriptions: StateSubscriptionManager
    ) -> Notify {
        { worktreeID, message in
            let notification = try await db.notifications.create(
                worktreeID: worktreeID, type: .attentionNeeded, message: message)
            subscriptions.broadcast(delta: .notificationReceived(NotificationDelta(
                notificationID: notification.id, worktreeID: notification.worktreeID,
                type: notification.type, message: notification.message,
                terminalID: notification.terminalID)))
        }
    }
}
