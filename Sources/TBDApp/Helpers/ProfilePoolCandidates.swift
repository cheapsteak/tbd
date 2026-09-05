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
            let hasCredential: Bool
            if kind == .oauth {
                hasCredential = entry.loginIdentity != nil
            } else if kind == .oauthToken {
                // oauthToken profile has credential if snapshot statusKind is not
                // .needsLogin or .noCredentials
                if let snapshot = entry.usageSnapshot {
                    hasCredential = snapshot.statusKind != .needsLogin
                        && snapshot.statusKind != .noCredentials
                } else {
                    hasCredential = false
                }
            } else {
                hasCredential = false
            }

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
}
