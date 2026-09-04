import Foundation

/// What the daemon is allowed to do about a newer `main`.
///
/// The one policy the daemon holds, because the timer that runs the check has
/// to live in a long-lived process and the daemon is the only one TBD owns.
/// Everything else about updating — how often, how many sessions to wake, which
/// configuration to build — lives in `scripts/update.sh` where an operator can
/// edit it without a rebuild.
public enum UpdateMode: String, Codable, Sendable, CaseIterable {
    /// Ships here. No timer runs, no network call is made, nothing is spawned.
    case off
    /// Observe only: a periodic `git ls-remote` records what `main` is at.
    /// Read-only — it moves no objects and writes to no worktree.
    case check
    /// Observe, and when the running build is behind, launch
    /// `scripts/update.sh --auto` once per newly-seen commit.
    case auto

    /// Whether this mode runs the periodic check at all. `off` is the only
    /// mode that does no work.
    public var runsChecks: Bool { self != .off }

    /// Whether this mode may launch the update script on its own.
    public var launchesUpdates: Bool { self == .auto }

    /// What `tbd config set update-mode` and the Settings picker show.
    public var displayName: String { rawValue }
}

/// How the running build relates to the latest commit on `main`.
///
/// Three cases, deliberately — a fourth ("diverged") would describe a state the
/// update path treats identically to `upToDate`: there is nothing to move
/// forward to that would not throw away commits the running build has.
public enum UpdateRelation: String, Codable, Sendable, CaseIterable {
    /// The running build already contains the latest commit — either it *is*
    /// that commit, or it carries commits `main` does not. Nothing to install.
    case upToDate
    /// The latest commit contains the running build's commit, or contains-ness
    /// could not be decided locally. An update would move forward.
    case behind
    /// Not enough is known to say: no build identity, or no answer from the
    /// remote yet.
    case unknown

    /// Decide the relation from the two commits and one ancestry answer.
    ///
    /// - Parameters:
    ///   - ours: the running build's commit, or nil when its identity is unknown.
    ///   - latest: the remote's `main` head, or nil when no check has succeeded.
    ///   - oursIsAncestorOfLatest: whether `latest` contains `ours`, as decided
    ///     by `git merge-base --is-ancestor` in the source worktree. **`nil`
    ///     means undecidable** — usually because the latest commit is not
    ///     present locally, which is itself evidence of being behind, so it
    ///     resolves to `.behind` (with no count).
    public static func compute(
        ours: String?,
        latest: String?,
        oursIsAncestorOfLatest: Bool?
    ) -> UpdateRelation {
        guard let ours, !ours.isEmpty, let latest, !latest.isEmpty else { return .unknown }
        if ours == latest { return .upToDate }
        switch oursIsAncestorOfLatest {
        case true:
            return .behind
        case false:
            // We hold commits `main` does not. A feature-branch build, or one
            // ahead of the remote. Nothing to install.
            return .upToDate
        case nil:
            // The latest commit is not in this worktree's object store, so
            // ancestry cannot be decided here. A commit we have never seen is
            // one we do not have.
            return .behind
        }
    }
}

/// The daemon's last observation of the remote's `main`.
///
/// Held in memory by `UpdateChecker` and republished on every `daemon.status`.
/// Nothing persists it: a restarted daemon has not checked yet, and saying so
/// is more honest than replaying an observation from before the restart.
public struct UpdateStatus: Codable, Sendable, Equatable {
    /// The remote's `main` head as last observed. Nil when no check succeeded.
    public let latestCommit: String?
    /// When that observation was made. Nil when no check succeeded.
    public let observedAt: Date?
    public let relation: UpdateRelation
    /// How many commits separate the running build from `latestCommit`, when a
    /// local `rev-list --count` could answer. Nil is the normal case on a fresh
    /// machine — the count needs the objects, and `ls-remote` fetches none.
    public let behindBy: Int?
    /// The remote URL that was consulted. Nil before the first resolution.
    public let remote: String?

    public init(
        latestCommit: String? = nil,
        observedAt: Date? = nil,
        relation: UpdateRelation = .unknown,
        behindBy: Int? = nil,
        remote: String? = nil
    ) {
        self.latestCommit = latestCommit
        self.observedAt = observedAt
        self.relation = relation
        self.behindBy = behindBy
        self.remote = remote
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        latestCommit = try c.decodeIfPresent(String.self, forKey: .latestCommit)
        observedAt = try c.decodeIfPresent(Date.self, forKey: .observedAt)
        // An unrecognised relation from a newer daemon is honestly `unknown`
        // rather than a decode failure that would lose the whole status.
        relation = (try? c.decode(UpdateRelation.self, forKey: .relation)) ?? .unknown
        behindBy = try c.decodeIfPresent(Int.self, forKey: .behindBy)
        remote = try c.decodeIfPresent(String.self, forKey: .remote)
    }

    /// Nothing observed yet.
    public static let unobserved = UpdateStatus()
}
