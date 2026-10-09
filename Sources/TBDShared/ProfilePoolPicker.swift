import Foundation

/// Candidate profile for account load-balancing pool selection.
///
/// Represents a single profile with its current usage, credential, and load information.
/// Used by `ProfilePoolPicker.pick(_:excludingAccountKeys:now:)` to score and rank profiles
/// for spawn-time placement and the hard-limit switch suggestion.
public struct ProfilePoolCandidate: Sendable, Equatable {
    /// The profile's unique identifier.
    public var profileID: UUID
    /// The credential kind: `.oauth` or `.oauthToken` profiles are pool-eligible;
    /// `.apiKey` and `.bedrock` are excluded (billed differently, no usage snapshot).
    public var kind: CredentialKind
    /// Whether the profile has a stored credential. Builders compute it with
    /// `ProfilePoolCandidate.hasCredential(kind:hasLoginIdentity:snapshotStatus:)`.
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

    /// Whether a profile holds a credential it could start a session with.
    ///
    /// The single rule both candidate builders use — the daemon's
    /// `ProfilePoolCandidateSource` and the app's picker ordering — so the app's
    /// "balanced pick" display cannot drift from the daemon's spawn-time choice.
    ///
    /// - `.oauth`: a login identity is known.
    /// - `.oauthToken`: the profile carries a stored token, so presence is assumed
    ///   unless the last usage probe reported `.needsLogin` or `.noCredentials`.
    ///   An absent snapshot only means the poller has not probed yet; the picker
    ///   still rejects such a profile, as `.noFreshReading`.
    /// - `.apiKey`, `.bedrock`: never — they are not pool-eligible.
    public static func hasCredential(
        kind: CredentialKind,
        hasLoginIdentity: Bool,
        snapshotStatus: ProfileUsageStatusKind?
    ) -> Bool {
        switch kind {
        case .oauth:
            return hasLoginIdentity
        case .oauthToken:
            guard let snapshotStatus else { return true }
            return snapshotStatus != .needsLogin && snapshotStatus != .noCredentials
        case .apiKey, .bedrock:
            return false
        }
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

    /// Profile's accountKey is in the excludingAccountKeys set (used by the
    /// hard-limit suggestion so it never names the exhausted account).
    case sameAccount

    /// Snapshot is absent or stale. The threshold is the policy's
    /// `stalenessWindow(for:)`: by default 300 seconds for `.oauth` and 900 for
    /// `.oauthToken`. A reading TBD would not display as current is not a
    /// reading it should route on.
    case noFreshReading

    /// The binding usage window is at or above the policy's usage ceiling (85%
    /// by default), so headroom is at or below `ProfilePoolPolicy.headroomFloor`.
    /// The profile is treated as full.
    case exhausted
}

/// The thresholds that decide whether a usage reading is safe to route a new
/// session on. Both are user-configurable (`tbd profile balancing`); the
/// defaults are the shipped behavior.
public struct ProfilePoolPolicy: Sendable, Equatable {
    /// The shipped usage ceiling, in percent.
    public static let defaultUsageCeilingPercent = 85
    /// The values `usageCeilingPercent` may take.
    public static let usageCeilingRange = 1...100
    /// The values `maxReadingAgeSeconds` may take: one minute to one day.
    public static let maxReadingAgeRange = 60...86_400

    /// A profile whose binding window is at or above this percent is full.
    ///
    /// Well short of 100, because a reading trails the work that moves it: it
    /// is minutes old when it is read, and every session already on the
    /// account keeps spending while a new one starts. A session placed at 95%
    /// dies on its first long turn; the margin is what keeps it from landing
    /// there.
    public var usageCeilingPercent: Int
    /// The oldest reading, in seconds, balancing routes on, applied to every
    /// kind alike. Nil keeps the cadence-relative default for each kind,
    /// `ProfilePoolPicker.stalenessWindow(for:)`.
    public var maxReadingAgeSeconds: Int?

    public init(
        usageCeilingPercent: Int = ProfilePoolPolicy.defaultUsageCeilingPercent,
        maxReadingAgeSeconds: Int? = nil
    ) {
        self.usageCeilingPercent = usageCeilingPercent
        self.maxReadingAgeSeconds = maxReadingAgeSeconds
    }

    /// The shipped thresholds.
    public static let standard = ProfilePoolPolicy()

    /// The policy a stored configuration describes: NULL columns, and values
    /// outside the accepted ranges (which the setters refuse, so only a
    /// hand-edited row can hold one), fall back to the shipped defaults.
    public static func resolved(usageCeilingPercent: Int?, maxReadingAgeSeconds: Int?) -> ProfilePoolPolicy {
        ProfilePoolPolicy(
            usageCeilingPercent: usageCeilingPercent.flatMap {
                usageCeilingRange.contains($0) ? $0 : nil
            } ?? defaultUsageCeilingPercent,
            maxReadingAgeSeconds: maxReadingAgeSeconds.flatMap {
                maxReadingAgeRange.contains($0) ? $0 : nil
            })
    }

    /// The oldest reading balancing routes on for `kind`.
    public func stalenessWindow(for kind: CredentialKind) -> TimeInterval {
        maxReadingAgeSeconds.map(TimeInterval.init) ?? ProfilePoolPicker.stalenessWindow(for: kind)
    }

    /// Headroom at or below this is full: `1 − ceiling/100`, rounded to a
    /// millionth like `ProfilePoolPicker.headroom(of:)` so a reading exactly at
    /// the ceiling lands on the floor rather than a hair above it.
    public var headroomFloor: Double {
        let raw = 1.0 - Double(usageCeilingPercent) / 100.0
        return (raw * 1_000_000).rounded() / 1_000_000
    }
}

/// Where a spawn lands when no candidate is eligible (design 2026-09-05 §6.3).
///
/// Only candidates turned away for their reading — full, or stale — are
/// considered: one that is opted out, has no credential, or is the wrong kind
/// was never a place balancing may put a session. Among those, the order is
/// predictable and explainable from the screen:
///
/// 1. A fresh reading that is over the ceiling but under 100% in every window
///    (`aboveCeiling`): least loaded first, by the picker's own score.
/// 2. No fresh reading (`staleReading`): least loaded by its last reading,
///    with a profile that has never had one after every profile that has.
/// 3. A fresh reading at 100% in some window (`full`): only when every
///    account is known to be at its limit.
///
/// Within a tier the picker's tie-breaks apply. The caller always tells the
/// person: a fallback is a session placed against the policy's advice.
public struct ProfilePoolFallback: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case aboveCeiling
        case staleReading
        case full
    }

    public var profileID: UUID
    public var reason: Reason

    public init(profileID: UUID, reason: Reason) {
        self.profileID = profileID
        self.reason = reason
    }
}

/// Decision outcome from `ProfilePoolPicker.pick(candidates:excludingAccountKeys:now:policy:)`.
///
/// Names the chosen profile (if any) and includes per-candidate verdicts for logging.
public struct ProfilePoolDecision: Sendable, Equatable {
    /// The profile id chosen for spawn or suggestion, or nil if no eligible profile exists.
    public var chosen: UUID?
    /// Verdict for every candidate in the input set, keyed by profileID.
    /// Even ineligible profiles appear so the resolver can log the reasoning.
    public var verdicts: [UUID: ProfilePoolVerdict]
    /// Where a spawn should land instead, when `chosen` is nil and some
    /// candidate was turned away only for its reading. Always nil when
    /// `chosen` is set. A suggestion ("X has room") must not use it.
    public var fallback: ProfilePoolFallback?

    public init(chosen: UUID?, verdicts: [UUID: ProfilePoolVerdict], fallback: ProfilePoolFallback? = nil) {
        self.chosen = chosen
        self.verdicts = verdicts
        self.fallback = fallback
    }
}

/// Pure account load-balancing picker for Claude profiles.
///
/// A stateless function that ranks profiles by available headroom and current load,
/// choosing the profile with the most room for a new session or a switch suggestion.
/// All scores and verdicts are deterministic and explainable from the input facts.
/// The picker holds no state and touches no I/O — it works entirely over the
/// candidate set passed in.
///
/// See `docs/specs/2026-09-05-account-load-balancing-design.md` § 5 for design rationale.
public enum ProfilePoolPicker {
    /// Pick the single best eligible profile from the candidate set.
    ///
    /// Returns a decision naming the chosen profile (lowest score, with tie-breaks
    /// applied) and verdicts for all candidates so the resolver can log each
    /// candidate's rejection reason.
    ///
    /// - Parameters:
    ///   - candidates: Profiles to consider.
    ///   - excludingAccountKeys: Account keys to exclude from eligibility (e.g.,
    ///     the exhausted account in a hard-limit suggestion). Profiles whose accountKey is in
    ///     this set are marked `.sameAccount` even if otherwise eligible.
    ///   - now: The current time for staleness assessment.
    ///   - policy: The usage ceiling and reading-age thresholds.
    ///
    /// - Returns: A decision with the chosen profile id (nil if none eligible),
    ///   verdicts for every candidate, and the fallback when nothing is eligible.
    public static func pick(
        candidates: [ProfilePoolCandidate],
        excludingAccountKeys: Set<String> = [],
        now: Date,
        policy: ProfilePoolPolicy = .standard
    ) -> ProfilePoolDecision {
        let verdicts = assessCandidates(
            candidates, excludingAccountKeys: excludingAccountKeys, now: now, policy: policy)
        let chosen = selectBest(from: candidates, with: verdicts)
        let fallback = chosen == nil ? selectFallback(from: candidates, with: verdicts) : nil
        return ProfilePoolDecision(chosen: chosen, verdicts: verdicts, fallback: fallback)
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
    ///   - policy: The usage ceiling and reading-age thresholds.
    ///
    /// - Returns: Array of eligible profile ids in score order (best first).
    ///   Empty if no profile is eligible.
    public static func ranked(
        candidates: [ProfilePoolCandidate],
        excludingAccountKeys: Set<String> = [],
        now: Date,
        policy: ProfilePoolPolicy = .standard
    ) -> [UUID] {
        let verdicts = assessCandidates(
            candidates, excludingAccountKeys: excludingAccountKeys, now: now, policy: policy)
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

    /// Default staleness threshold for a credential kind.
    ///
    /// Returns the maximum age a usage snapshot can have before it is considered
    /// stale and unsuitable for routing decisions, unless the policy overrides it
    /// (`ProfilePoolPolicy.maxReadingAgeSeconds`). The thresholds are
    /// cadence-relative: roughly 3x the polling interval for that kind.
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
        now: Date,
        policy: ProfilePoolPolicy
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
            let threshold = policy.stalenessWindow(for: candidate.kind)
            if age > threshold {
                verdicts[candidate.profileID] = .noFreshReading
                continue
            }

            // Rule 6: Headroom must be above the floor, i.e. usage below the
            // ceiling.
            let hr = headroom(of: snapshot)
            if hr <= policy.headroomFloor {
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

    /// The fallback when nothing is eligible (see `ProfilePoolFallback`), or nil
    /// when no candidate was turned away for its reading alone.
    private static func selectFallback(
        from candidates: [ProfilePoolCandidate],
        with verdicts: [UUID: ProfilePoolVerdict]
    ) -> ProfilePoolFallback? {
        let accountLoads = Dictionary(grouping: candidates, by: \.accountKey)
            .mapValues { $0.reduce(0) { $0 + $1.liveSessions } }

        struct Ranked {
            let candidate: ProfilePoolCandidate
            let reason: ProfilePoolFallback.Reason
            let tier: Int
            /// 0 when there is a reading to rank on, 1 when there is none.
            let unread: Int
            let score: Double
        }

        let ranked = candidates.compactMap { candidate -> Ranked? in
            let load = Double((accountLoads[candidate.accountKey] ?? 0) + 1)
            switch verdicts[candidate.profileID] {
            case .exhausted:
                // `.exhausted` is only reached past the freshness rule, so the
                // snapshot is present and current.
                let hr = candidate.snapshot.map(headroom(of:)) ?? 0
                if hr > 0 {
                    return Ranked(candidate: candidate, reason: .aboveCeiling, tier: 0,
                                  unread: 0, score: load / hr)
                }
                // Every full account is equally full; load alone orders them.
                return Ranked(candidate: candidate, reason: .full, tier: 2,
                              unread: 0, score: load)
            case .noFreshReading:
                guard let snapshot = candidate.snapshot, snapshot.fetchedAt != nil else {
                    return Ranked(candidate: candidate, reason: .staleReading, tier: 1,
                                  unread: 1, score: load)
                }
                // A last reading at 100% still ranks, just last: a floor keeps
                // the score finite so load can break the tie.
                let hr = max(headroom(of: snapshot), 0.001)
                return Ranked(candidate: candidate, reason: .staleReading, tier: 1,
                              unread: 0, score: load / hr)
            default:
                return nil
            }
        }

        let best = ranked.min { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.unread != rhs.unread { return lhs.unread < rhs.unread }
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return tieBreak(lhs.candidate, rhs.candidate) < 0
        }
        return best.map { ProfilePoolFallback(profileID: $0.candidate.profileID, reason: $0.reason) }
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

        return tieBreak(lhsCandidate, rhsCandidate)
    }

    /// The deterministic tie-break shared by the pick and the fallback.
    /// Returns < 0 if lhs comes first.
    private static func tieBreak(
        _ lhsCandidate: ProfilePoolCandidate,
        _ rhsCandidate: ProfilePoolCandidate
    ) -> Int {
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
