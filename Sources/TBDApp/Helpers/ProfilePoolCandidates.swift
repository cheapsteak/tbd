import Foundation
import TBDShared

/// Build `ProfilePoolCandidate` set from app state for ranking by `ProfilePoolPicker`.
enum ProfilePoolCandidates {
    /// Construct candidates from the app's model profiles and terminal state.
    ///
    /// - `entries`: The daemon's list of profiles with usage snapshots.
    /// - `liveCounts`: A closure that returns the live session count for a given profile ID.
    /// - `defaultProfileID`: The configured global default, if any.
    /// - Returns: Array of candidates ready for `ProfilePoolPicker.ranked()`.
    static func fromApp(
        entries: [ModelProfileWithUsage],
        liveCounts: (UUID) -> Int,
        defaultProfileID: UUID?
    ) -> [ProfilePoolCandidate] {
        entries.map { entry in
            let profile = entry.profile
            let kind = profile.kind
            let liveCount = liveCounts(profile.id)
            // The same rule the daemon's candidate source uses, so the
            // balanced pick shown here matches the one a spawn would make.
            let hasCredential = ProfilePoolCandidate.hasCredential(
                kind: kind,
                hasLoginIdentity: entry.loginIdentity != nil,
                snapshotStatus: entry.usageSnapshot?.statusKind
            )

            // Account key: snapshot.organizationID ?? loginIdentity ?? profileID string
            let accountKey = entry.usageSnapshot?.organizationID
                ?? entry.loginIdentity
                ?? profile.id.uuidString

            return ProfilePoolCandidate(
                profileID: profile.id,
                kind: kind,
                hasCredential: hasCredential,
                poolOptOut: profile.poolOptOut,
                accountKey: accountKey,
                snapshot: entry.usageSnapshot,
                liveSessions: liveCount,
                sortOrder: profile.sortOrder,
                isConfiguredDefault: profile.id == defaultProfileID
            )
        }
    }

    /// Whether a Settings row shows the "stale — skipped by balancing" badge
    /// (design 2026-09-05 §6.1): only while balancing is on, and only for a
    /// profile the picker skips as `noFreshReading` — an account that is
    /// otherwise in the pool but whose reading balancing cannot use.
    static func showsStaleBadge(balancingOn: Bool, verdict: ProfilePoolVerdict?) -> Bool {
        guard balancingOn, let verdict else { return false }
        if case .noFreshReading = verdict { return true }
        return false
    }

    /// The profiles whose Settings rows carry the stale badge, judged by the
    /// same candidate rule and picker the daemon's balanced pick uses. Empty
    /// while balancing is off. Live counts only affect scoring, never the
    /// verdict, so none are needed here.
    static func staleBadgeProfileIDs(
        entries: [ModelProfileWithUsage],
        balancingOn: Bool,
        defaultProfileID: UUID?,
        now: Date
    ) -> Set<UUID> {
        guard balancingOn else { return [] }
        let candidates = fromApp(
            entries: entries, liveCounts: { _ in 0 }, defaultProfileID: defaultProfileID)
        let verdicts = ProfilePoolPicker.pick(candidates: candidates, now: now).verdicts
        return Set(verdicts.compactMap { id, verdict in
            showsStaleBadge(balancingOn: balancingOn, verdict: verdict) ? id : nil
        })
    }
}
