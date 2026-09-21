import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "profilePoolCandidateSource")

/// Assembles candidate profiles for account load-balancing pool selection.
///
/// The source builds a ranked list of profiles with their current usage, credential status,
/// and live session counts, sourcing facts from the profile store, usage snapshots,
/// terminal state, and login identities. Used by `ModelProfileResolver` to implement
/// spawn-time load balancing when the `profileBalancingEnabled` flag is on.
public struct ProfilePoolCandidateSource: Sendable {
    let profiles: ModelProfileStore
    let snapshots: OAuthUsageSnapshotStore
    let terminals: TerminalStore
    let loginIdentity: @Sendable (UUID) -> String?
    let now: @Sendable () -> Date

    /// Initialize a candidate source with injected dependencies.
    ///
    /// - Parameters:
    ///   - profiles: The model profile store to list all profiles.
    ///   - snapshots: The usage snapshot store to load per-profile snapshots.
    ///   - terminals: The terminal store to query live session counts.
    ///   - loginIdentity: A closure that returns the login email for a profile, or nil.
    ///   - now: A closure returning the current date for staleness assessment.
    ///     Defaults to `Date()`.
    public init(
        profiles: ModelProfileStore,
        snapshots: OAuthUsageSnapshotStore,
        terminals: TerminalStore,
        loginIdentity: @Sendable @escaping (UUID) -> String?,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.profiles = profiles
        self.snapshots = snapshots
        self.terminals = terminals
        self.loginIdentity = loginIdentity
        self.now = now
    }

    /// Build the candidate list for the pool picker.
    ///
    /// Assembles one candidate per profile row: loads the usage snapshot (if available),
    /// determines credential presence (for oauth: loginIdentity != nil; for oauthToken:
    /// snapshot statusKind not in [.needsLogin, .noCredentials], or true if no snapshot
    /// yet), looks up live session count, and computes the account key (snapshot.organizationID ??
    /// loginIdentity ?? profileID.uuidString).
    ///
    /// - Parameters:
    ///   - defaultProfileID: The global configured default profile ID. Used to mark
    ///     `isConfiguredDefault` on the matching candidate.
    ///
    /// - Returns: Array of `ProfilePoolCandidate` objects, one per profile.
    public func candidates(defaultProfileID: UUID?) async throws -> [ProfilePoolCandidate] {
        let allProfiles = try await profiles.list()
        let allSnapshots = try await snapshots.loadAll()
        let liveCounts = try await terminals.liveSessionCountsByProfile()

        return allProfiles.map { row in
            let snapshot = allSnapshots[row.id]

            // Determine hasCredential per the design:
            // - .oauth: loginIdentity != nil
            // - .oauthToken: snapshot statusKind not in [.needsLogin, .noCredentials]
            //   (or true if no snapshot yet — the token profile carries a credential)
            // - .apiKey, .bedrock: false (not pool-eligible)
            let hasCredential: Bool
            switch row.kind {
            case .oauth:
                hasCredential = loginIdentity(row.id) != nil
            case .oauthToken:
                if let snapshot = snapshot {
                    hasCredential = ![ProfileUsageSnapshot.StatusKind.needsLogin, .noCredentials]
                        .contains(snapshot.statusKind)
                } else {
                    // No snapshot yet: assume the token is stored (the profile wouldn't exist without one).
                    hasCredential = true
                }
            case .apiKey, .bedrock:
                hasCredential = false
            }

            // Compute account key: organizationID ?? loginIdentity ?? profileID.uuidString.
            let accountKey: String
            if let orgID = snapshot?.organizationID, !orgID.isEmpty {
                accountKey = orgID
            } else if let identity = loginIdentity(row.id), !identity.isEmpty {
                accountKey = identity
            } else {
                accountKey = row.id.uuidString
            }

            let liveCount = liveCounts[row.id] ?? 0
            let isDefault = row.id == defaultProfileID

            return ProfilePoolCandidate(
                profileID: row.id,
                kind: row.kind,
                hasCredential: hasCredential,
                poolOptOut: row.poolOptOut == true,
                accountKey: accountKey,
                snapshot: snapshot,
                liveSessions: liveCount,
                sortOrder: row.sortOrder,
                isConfiguredDefault: isDefault
            )
        }
    }

    /// Return the account key for a single profile.
    ///
    /// Looks up the profile's account grouping key (snapshot.organizationID ??
    /// loginIdentity ?? profileID.uuidString) without assembling the full candidate list.
    /// Used by the rotation worker to determine the excluded account key when suggesting
    /// a rotation target.
    ///
    /// - Parameter profileID: The profile to look up.
    /// - Returns: The account key string, or nil if the profile does not exist.
    public func accountKey(forProfileID profileID: UUID) async throws -> String? {
        guard let row = try await profiles.get(id: profileID) else { return nil }

        let snapshot = try await snapshots.loadAll()[profileID]

        // Same logic as candidates(defaultProfileID:) above.
        let accountKey: String
        if let orgID = snapshot?.organizationID, !orgID.isEmpty {
            accountKey = orgID
        } else if let identity = loginIdentity(profileID), !identity.isEmpty {
            accountKey = identity
        } else {
            accountKey = profileID.uuidString
        }

        return accountKey
    }
}
