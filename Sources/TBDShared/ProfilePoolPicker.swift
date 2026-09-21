import Foundation

/// Candidate profile for account load-balancing pool selection.
///
/// Represents a single profile with its current usage, credential, and load information.
/// Used by `ProfilePoolPicker.pick(_:excludingAccountKeys:now:)` to score and rank profiles
/// for spawn-time and limit-rotation decisions.
public struct ProfilePoolCandidate: Sendable, Equatable {
    /// The profile's unique identifier.
    public var profileID: UUID
    /// The credential kind: `.oauth` or `.oauthToken` profiles are pool-eligible;
    /// `.apiKey` and `.bedrock` are excluded (billed differently, no usage snapshot).
    public var kind: CredentialKind
    /// Whether the profile has a stored credential (hasCredential = oauth: loginIdentity != nil;
    /// oauthToken: snapshot statusKind not .needsLogin/.noCredentials).
    public var hasCredential: Bool
    /// Whether the user has opted this profile out of the balancing pool.
    public var poolOptOut: Bool
    /// The profile's account grouping key (derived by caller as snapshot.organizationID ??
    /// loginIdentity ?? profileID.uuidString). Two profiles with the same accountKey are
    /// treated as one account for load pooling and exclusion.
    public var accountKey: String
    /// The profile's cached usage snapshot, if available. nil when the poller has not yet
    /// attempted a fetch, or for non-oauth kinds.
    public var snapshot: ProfileUsageSnapshot?
    /// Live Claude sessions running under this profile alone (not summed across the account).
    /// A parked or non-Claude session does not count.
    public var liveSessions: Int
    /// Display order (0-based, mirrors Worktree.sortOrder). Used as a tie-breaker.
    public var sortOrder: Int
    /// Whether this profile is the global configured default.
    public var isConfiguredDefault: Bool

    public init(
        profileID: UUID,
        kind: CredentialKind,
        hasCredential: Bool,
        poolOptOut: Bool,
        accountKey: String,
        snapshot: ProfileUsageSnapshot? = nil,
        liveSessions: Int,
        sortOrder: Int,
        isConfiguredDefault: Bool
    ) {
        self.profileID = profileID
        self.kind = kind
        self.hasCredential = hasCredential
        self.poolOptOut = poolOptOut
        self.accountKey = accountKey
        self.snapshot = snapshot
        self.liveSessions = liveSessions
        self.sortOrder = sortOrder
        self.isConfiguredDefault = isConfiguredDefault
    }
}

/// Result of eligibility assessment for a single profile candidate.
///
/// Each verdict explains why a profile was rejected, or (for `.eligible`) how it scored
/// if accepted. Verdicts are returned for all candidates so the resolver can log the
/// reasoning.
public enum ProfilePoolVerdict: Sendable, Equatable {
    /// Profile is eligible and its score for ranking.
    /// - `score`: `(accountLiveSessions + 1) / headroom`, lower is better.
    /// - `headroom`: `1 - max(percent)/100` over binding window buckets, clamped to [0, 1].
    /// - `accountLiveSessions`: sum of liveSessions across all candidates sharing this
    ///   profile's accountKey (eligible or not), reflecting the load being balanced.
    case eligible(score: Double, headroom: Double, accountLiveSessions: Int)

    /// Kind is not `.oauth` or `.oauthToken`; profile is not pool-eligible.
    case wrongKind

    /// No stored credential (oauth: loginIdentity == nil, oauthToken: statusKind is
    /// .needsLogin or .noCredentials). Profile cannot start a session.
    case noCredential

    /// Profile is opted out of the pool (poolOptOut == true).
    case optedOut

    /// Profile's accountKey is in the excludingAccountKeys set (used in rotation to
    /// avoid swapping a session to the same account).
    case sameAccount

    /// Snapshot is absent or stale. The threshold is `stalenessWindow(for: kind)`:
    /// 300 seconds for `.oauth`, 900 for `.oauthToken`. A reading TBD would not
    /// display as current is not a reading it should route on.
    case noFreshReading

    /// Headroom (room in the binding usage window) is at or below the 5% floor
    /// (headroom <= 0.05). The profile is effectively full.
    case exhausted
}

/// Decision outcome from `ProfilePoolPicker.pick(_:excludingAccountKeys:now:)`.
///
/// Names the chosen profile (if any) and includes per-candidate verdicts for logging.
public struct ProfilePoolDecision: Sendable, Equatable {
    /// The profile id chosen for spawn/rotation, or nil if no eligible profile exists.
    public var chosen: UUID?
    /// Verdict for every candidate in the input set, keyed by profileID.
    /// Even ineligible profiles appear so the resolver can log the reasoning.
    public var verdicts: [UUID: ProfilePoolVerdict]

    public init(chosen: UUID?, verdicts: [UUID: ProfilePoolVerdict]) {
        self.chosen = chosen
        self.verdicts = verdicts
    }
}

/// Pure account load-balancing picker for Claude profiles.
///
/// A stateless function that ranks profiles by available headroom and current load,
/// choosing the profile with the most room for a new session or rotation target.
/// All scores and verdicts are deterministic and explainable from the input facts.
/// The picker holds no state and touches no I/O — it works entirely over the
/// candidate set passed in.
///
/// See `docs/specs/2026-09-05-account-load-balancing-design.md` § 5 for design rationale.
public enum ProfilePoolPicker {
    /// The minimum headroom required (5%). A profile at 96% utilization or higher
    /// is treated as exhausted, not ranked last, because a session landing there
    /// will die on its first long turn.
    public static let headroomFloor: Double = 0.05

    /// Pick the single best eligible profile from the candidate set.
    ///
    /// Returns a decision naming the chosen profile (lowest score, with tie-breaks
    /// applied) and verdicts for all candidates so the resolver can log each
    /// candidate's rejection reason.
    ///
    /// - Parameters:
    ///   - candidates: Profiles to consider.
    ///   - excludingAccountKeys: Account keys to exclude from eligibility (e.g.,
    ///     the exhausted account in a rotation). Profiles whose accountKey is in
    ///     this set are marked `.sameAccount` even if otherwise eligible.
    ///   - now: The current time for staleness assessment.
    ///
    /// - Returns: A decision with the chosen profile id (nil if none eligible)
    ///   and verdicts for every candidate.
    public static func pick(
        candidates: [ProfilePoolCandidate],
        excludingAccountKeys: Set<String> = [],
        now: Date
    ) -> ProfilePoolDecision {
        let verdicts = assessCandidates(candidates, excludingAccountKeys: excludingAccountKeys, now: now)
        let chosen = selectBest(from: candidates, with: verdicts)
        return ProfilePoolDecision(chosen: chosen, verdicts: verdicts)
    }

    /// Ranked list of eligible profiles by score (lowest score first).
    ///
    /// Returns only eligible profiles in ascending score order, respecting all
    /// the same eligibility rules as `pick(_:excludingAccountKeys:now:)`.
    /// The first element is the same profile `pick()` would choose.
    ///
    /// - Parameters:
    ///   - candidates: Profiles to consider.
    ///   - excludingAccountKeys: Account keys to exclude from eligibility.
    ///   - now: The current time for staleness assessment.
    ///
    /// - Returns: Array of eligible profile ids in score order (best first).
    ///   Empty if no profile is eligible.
    public static func ranked(
        candidates: [ProfilePoolCandidate],
        excludingAccountKeys: Set<String> = [],
        now: Date
    ) -> [UUID] {
        let verdicts = assessCandidates(candidates, excludingAccountKeys: excludingAccountKeys, now: now)
        let eligible = candidates.compactMap { candidate -> (candidate: ProfilePoolCandidate, verdict: ProfilePoolVerdict)? in
            guard case .eligible = verdicts[candidate.profileID] else { return nil }
            return (candidate, verdicts[candidate.profileID]!)
        }
        return eligible
            .sorted { lhs, rhs in
                compareCandidates(lhs.candidate, lhs.verdict, rhs.candidate, rhs.verdict) < 0
            }
            .map(\.candidate.profileID)
    }

    /// Headroom as a fraction (0.0 to 1.0) for a usage snapshot.
    ///
    /// Headroom is `1 - max(percent)/100` over the binding window — the buckets
    /// with kind "session", "weekly_all", and active "weekly_scoped" (isActive == true).
    /// An inactive bucket (isActive == false) is ignored. A snapshot with no such
    /// buckets returns 1.0 (unlimited headroom). Percent values > 100 are clamped
    /// to 100 before subtraction.
    ///
    /// - Parameter snapshot: The usage snapshot to assess.
    /// - Returns: Headroom in [0.0, 1.0], where 1.0 means unlimited and 0.0 means exhausted.
    public static func headroom(of snapshot: ProfileUsageSnapshot) -> Double {
        let bindingBuckets = snapshot.buckets.filter { bucket in
            let isBindingKind = ["session", "weekly_all", "weekly_scoped"].contains(bucket.kind)
            let isActive = bucket.isActive != false  // nil and true both count
            return isBindingKind && isActive
        }

        guard !bindingBuckets.isEmpty else { return 1.0 }

        let maxPercent = bindingBuckets.map { min($0.percent, 100.0) }.max() ?? 0.0
        // Round to a millionth so a reading of exactly 95% lands on the 0.05
        // floor rather than a hair above it (1 - 0.95 is 0.050000000000000044
        // in binary floating point), and equal readings compare equal.
        let raw = max(0.0, 1.0 - (maxPercent / 100.0))
        return (raw * 1_000_000).rounded() / 1_000_000
    }

    /// Staleness threshold for a credential kind.
    ///
    /// Returns the maximum age a usage snapshot can have before it is considered
    /// stale and unsuitable for routing decisions. The thresholds are cadence-relative:
    /// roughly 3x the polling interval for that kind.
    ///
    /// - `.oauth`: 300 seconds (5 minutes). Signed-in profiles are refreshed ~90s;
    ///   five minutes means several consecutive misses.
    /// - `.oauthToken`: 900 seconds (15 minutes). Token profiles refresh on a
    ///   five-minute activity floor; without the longer threshold, the reading would
    ///   be marked stale the instant it was fetched.
    /// - `.apiKey`, `.bedrock`: 300 seconds (unchanged; these kinds are not pool-eligible
    ///   and this function is documented for reference completeness).
    ///
    /// See `Sources/TBDApp/Helpers/ProfileUsagePresentation.staleAge` for the
    /// corresponding app-side display threshold.
    ///
    /// - Parameter kind: The credential kind.
    /// - Returns: Staleness threshold in seconds.
    public static func stalenessWindow(for kind: CredentialKind) -> TimeInterval {
        switch kind {
        case .oauthToken: return 900
        case .oauth, .apiKey, .bedrock: return 300
        }
    }

    // MARK: - Private Implementation

    /// Assess each candidate against eligibility rules, returning verdicts.
    private static func assessCandidates(
        _ candidates: [ProfilePoolCandidate],
        excludingAccountKeys: Set<String>,
        now: Date
    ) -> [UUID: ProfilePoolVerdict] {
        // Pre-compute live session counts per account key (sum across all candidates,
        // eligible or not, so an opted-out twin still occupies its account's windows).
        let accountLiveSessionCounts = Dictionary(
            grouping: candidates, by: { $0.accountKey }
        ).mapValues { accountCandidates in
            accountCandidates.reduce(0) { $0 + $1.liveSessions }
        }

        var verdicts: [UUID: ProfilePoolVerdict] = [:]

        for candidate in candidates {
            // Rule 1: Kind must be .oauth or .oauthToken.
            if candidate.kind != .oauth && candidate.kind != .oauthToken {
                verdicts[candidate.profileID] = .wrongKind
                continue
            }

            // Rule 2: hasCredential must be true.
            if !candidate.hasCredential {
                verdicts[candidate.profileID] = .noCredential
                continue
            }

            // Rule 3: Must not be opted out.
            if candidate.poolOptOut {
                verdicts[candidate.profileID] = .optedOut
                continue
            }

            // Rule 4: accountKey must not be in the excluded set.
            if excludingAccountKeys.contains(candidate.accountKey) {
                verdicts[candidate.profileID] = .sameAccount
                continue
            }

            // Rule 5: Snapshot must be present and fresh.
            guard let snapshot = candidate.snapshot else {
                verdicts[candidate.profileID] = .noFreshReading
                continue
            }

            guard let fetchedAt = snapshot.fetchedAt else {
                verdicts[candidate.profileID] = .noFreshReading
                continue
            }

            let age = now.timeIntervalSince(fetchedAt)
            let threshold = stalenessWindow(for: candidate.kind)
            if age > threshold {
                verdicts[candidate.profileID] = .noFreshReading
                continue
            }

            // Rule 6: Headroom must be above the floor.
            let hr = headroom(of: snapshot)
            if hr <= headroomFloor {
                verdicts[candidate.profileID] = .exhausted
                continue
            }

            // All rules passed; compute the score.
            let accountLoad = accountLiveSessionCounts[candidate.accountKey] ?? 0
            let score = Double(accountLoad + 1) / hr

            verdicts[candidate.profileID] = .eligible(
                score: score,
                headroom: hr,
                accountLiveSessions: accountLoad
            )
        }

        return verdicts
    }

    /// Select the best eligible profile from verdicts, applying tie-breaks.
    private static func selectBest(
        from candidates: [ProfilePoolCandidate],
        with verdicts: [UUID: ProfilePoolVerdict]
    ) -> UUID? {
        let eligible = candidates.compactMap { candidate -> (candidate: ProfilePoolCandidate, verdict: ProfilePoolVerdict)? in
            guard case .eligible = verdicts[candidate.profileID] else { return nil }
            return (candidate, verdicts[candidate.profileID]!)
        }

        guard !eligible.isEmpty else { return nil }

        let best = eligible.min { lhs, rhs in
            compareCandidates(lhs.candidate, lhs.verdict, rhs.candidate, rhs.verdict) < 0
        }

        return best?.candidate.profileID
    }

    /// Compare two candidates for ordering. Returns < 0 if lhs is better.
    private static func compareCandidates(
        _ lhsCandidate: ProfilePoolCandidate,
        _ lhsVerdict: ProfilePoolVerdict,
        _ rhsCandidate: ProfilePoolCandidate,
        _ rhsVerdict: ProfilePoolVerdict
    ) -> Int {
        guard case let .eligible(lhsScore, _, _) = lhsVerdict,
              case let .eligible(rhsScore, _, _) = rhsVerdict else {
            return 0  // Neither should be called if not eligible
        }

        // Score first: lower is better. Only equal scores reach the tie-breaks.
        if lhsScore != rhsScore {
            return lhsScore < rhsScore ? -1 : 1
        }

        // Tie-break 1: Configured default first
        if lhsCandidate.isConfiguredDefault != rhsCandidate.isConfiguredDefault {
            return lhsCandidate.isConfiguredDefault ? -1 : 1
        }

        // Tie-break 2: Lower sortOrder
        if lhsCandidate.sortOrder != rhsCandidate.sortOrder {
            return lhsCandidate.sortOrder < rhsCandidate.sortOrder ? -1 : 1
        }

        // Tie-break 3: ProfileID string ascending
        let lhsIDStr = lhsCandidate.profileID.uuidString
        let rhsIDStr = rhsCandidate.profileID.uuidString
        if lhsIDStr != rhsIDStr {
            return lhsIDStr < rhsIDStr ? -1 : 1
        }

        // All tie-breaks equal (shouldn't happen with unique UUIDs)
        return 0
    }
}
