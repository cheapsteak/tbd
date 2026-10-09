import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "modelProfileResolver")

/// Tells the person when a balanced pick found no account it may route on and
/// placed the session on the picker's fallback instead (design 2026-09-05
/// §6.3).
///
/// A fallback is a session placed against the policy's own advice — on an
/// account over the usage ceiling, on one whose reading is stale, or, when
/// every account is at its limit, on a full one — so it is never silent. The
/// resolver logs every one; this posts one `.attentionNeeded` notification on
/// the spawning worktree naming the account, its last reading, and why.
///
/// An in-memory latch keyed by profile holds that to once per account per
/// episode: a burst of spawns that all fall back to the same account tells the
/// person once, and a fallback to a different account tells them again. The
/// latch clears whole when a balanced pick next finds an eligible account,
/// which ends the episode, so a relapse notifies again. A daemon restart
/// clears it too, costing at most one repeat notification.
///
/// Only balanced picks feed it, exactly as with `StaleAccountAlerts`; there is
/// one instance per daemon, built in `Daemon.swift` and shared by every copy
/// of the resolver.
public actor BalancingFallbackAlerts {
    /// Same shape as `StaleAccountAlerts.Notify`; production wiring is
    /// `StaleAccountAlerts.notifier(db:subscriptions:)`.
    public typealias Notify = StaleAccountAlerts.Notify

    private var latched: Set<UUID> = []
    private let notify: Notify

    public init(notify: @escaping Notify) {
        self.notify = notify
    }

    /// Feed one balanced pick's outcome.
    ///
    /// - Parameters:
    ///   - candidates: The candidates the picker judged.
    ///   - decision: Its decision. A chosen profile ends the episode; a
    ///     fallback is what gets reported.
    ///   - policy: The thresholds the pick applied, named in the message.
    ///   - worktreeID: The spawning worktree. Nil notifies nobody and latches
    ///     nothing, so the next spawn that has a worktree still tells the person.
    ///   - now: The time the pick judged staleness against.
    ///   - profileName: Looks up the display name for the message.
    public func observe(
        candidates: [ProfilePoolCandidate],
        decision: ProfilePoolDecision,
        policy: ProfilePoolPolicy,
        worktreeID: UUID?,
        now: Date,
        profileName: @Sendable (UUID) async -> String?
    ) async {
        guard decision.chosen == nil else {
            latched.removeAll()
            return
        }
        guard let fallback = decision.fallback, let worktreeID else { return }
        // Claimed before any suspension, so two concurrent fallbacks to the
        // same account cannot both notify.
        guard latched.insert(fallback.profileID).inserted else { return }
        let name = await profileName(fallback.profileID)
            ?? String(fallback.profileID.uuidString.prefix(8))
        let snapshot = candidates.first { $0.profileID == fallback.profileID }?.snapshot
        let message = Self.message(
            profileName: name, reason: fallback.reason, snapshot: snapshot,
            policy: policy, now: now)
        do {
            try await notify(worktreeID, message)
            logger.info("balancing fallback to \(fallback.profileID, privacy: .public) surfaced on worktree \(worktreeID, privacy: .public)")
        } catch {
            // Unlatch so a later fallback retries; never fail the spawn.
            latched.remove(fallback.profileID)
            logger.error("balancing fallback notification failed for \(fallback.profileID, privacy: .public): \(error, privacy: .public)")
        }
    }

    /// Whether a profile is currently latched. For tests.
    public func isLatched(_ profileID: UUID) -> Bool {
        latched.contains(profileID)
    }

    /// The notification text: why nothing was eligible, where the session
    /// went, and the reading that put it there.
    public static func message(
        profileName: String,
        reason: ProfilePoolFallback.Reason,
        snapshot: ProfileUsageSnapshot?,
        policy: ProfilePoolPolicy,
        now: Date
    ) -> String {
        let usage = snapshot.flatMap(usageSummary(of:))
        switch reason {
        case .aboveCeiling:
            let reading = usage.map { " (\($0))" } ?? ""
            return "No account is under the \(policy.usageCeilingPercent)% balancing limit with a fresh reading — this session started on \(profileName), the least used\(reading)"
        case .staleReading:
            guard let fetchedAt = snapshot?.fetchedAt else {
                return "No account has a fresh usage reading under the \(policy.usageCeilingPercent)% balancing limit — this session started on \(profileName), which has no usage reading yet"
            }
            let minutes = max(0, Int((now.timeIntervalSince(fetchedAt) / 60).rounded(.down)))
            let reading = usage.map { "\($0), " } ?? ""
            return "No account has a fresh usage reading under the \(policy.usageCeilingPercent)% balancing limit — this session started on \(profileName) by its last reading (\(reading)\(minutes) min old)"
        case .full:
            let reading = usage.map { " (\($0))" } ?? ""
            return "Every account is at its usage limit — this session started on \(profileName)\(reading) and may stop on its first turn"
        }
    }

    /// "5h 61% · week 38%" from the session and weekly-all buckets, or nil
    /// when the snapshot carries neither.
    static func usageSummary(of snapshot: ProfileUsageSnapshot) -> String? {
        var parts: [String] = []
        if let session = snapshot.buckets.first(where: { $0.kind == "session" }) {
            parts.append("5h \(Int(session.percent))%")
        }
        if let weekly = snapshot.buckets.first(where: { $0.kind == "weekly_all" }) {
            parts.append("week \(Int(weekly.percent))%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
