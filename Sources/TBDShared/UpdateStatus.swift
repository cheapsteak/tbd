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

/// Whether the latest commit on `main` contains the running build's commit.
///
/// Four cases rather than an optional `Bool`, because the two ways an ancestry
/// question goes unanswered call for opposite conclusions and an optional
/// cannot tell them apart. `git merge-base --is-ancestor` reports both "the
/// commit you named is not in this object store" and "this repository could not
/// answer" as a non-zero exit that is not 1, and in `auto` mode the difference
/// is whether a transient git failure installs a new build.
public enum AncestryAnswer: String, Codable, Sendable, CaseIterable {
    /// `latest` contains `ours`: the running build is on the same line and
    /// behind it.
    case contains
    /// `latest` does not contain `ours`: the running build holds commits `main`
    /// does not.
    case doesNotContain
    /// Ancestry is undecidable because `latest` is not in the local object
    /// store. A commit we have never seen is one we do not have, so this is
    /// evidence of being behind rather than an absence of evidence.
    case latestAbsentLocally
    /// Ancestry is undecidable because the repository did not answer — a bad
    /// ref, a corrupt or missing object store, a timed-out subprocess. Evidence
    /// in no direction at all.
    case undecided
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
    /// The latest commit contains the running build's commit, or names a commit
    /// this machine has never seen. An update would move forward.
    case behind
    /// Not enough is known to say: no build identity, no answer from the remote
    /// yet, or a local repository that could not decide ancestry.
    case unknown

    /// Decide the relation from the two commits and one ancestry answer.
    ///
    /// - Parameters:
    ///   - ours: the running build's commit, or nil when its identity is unknown.
    ///   - latest: the remote's `main` head, or nil when no check has succeeded.
    ///   - ancestry: whether `latest` contains `ours`, as decided in the source
    ///     worktree. Its two undecided cases part company here: a latest commit
    ///     absent from the local object store is evidence of being behind, while
    ///     a repository that could not answer is evidence of nothing and
    ///     resolves to `.unknown`, which never launches an update.
    public static func compute(
        ours: String?,
        latest: String?,
        ancestry: AncestryAnswer
    ) -> UpdateRelation {
        guard let ours, !ours.isEmpty, let latest, !latest.isEmpty else { return .unknown }
        if ours == latest { return .upToDate }
        switch ancestry {
        case .contains:
            return .behind
        case .doesNotContain:
            // We hold commits `main` does not. A feature-branch build, or one
            // ahead of the remote. Nothing to install.
            return .upToDate
        case .latestAbsentLocally:
            // The latest commit is not in this worktree's object store, so
            // ancestry cannot be decided here. A commit we have never seen is
            // one we do not have.
            return .behind
        case .undecided:
            // The repository could not answer. Saying `behind` here would let a
            // bad ref or a corrupt object store install a build in `auto` mode
            // on no evidence at all.
            return .unknown
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
    /// The ref `latestCommit` was read from: `refs/heads/main` when the check
    /// follows `main`, `refs/tags/<tag>` when it follows the published release
    /// (update source `release`). Nil from a daemon that does not report it,
    /// which readers must treat as "measured against `main`".
    public let comparedRef: String?
    /// Whether an update installs without a gesture: `update_mode` is `auto`,
    /// or an external auto-updater has switched itself on. Nil from a daemon
    /// that does not report it, which readers must treat as "not auto" — the
    /// previous behaviour, where the notice shows.
    public let autoUpdateActive: Bool?
    /// When this daemon first saw `latestCommit` as the compared ref's head.
    /// In memory in the daemon, so a restart restarts the clock; nil when
    /// unknown. Lets the app tell a release that has just landed from one that
    /// has been waiting for days.
    public let latestFirstSeenAt: Date?

    public init(
        latestCommit: String? = nil,
        observedAt: Date? = nil,
        relation: UpdateRelation = .unknown,
        behindBy: Int? = nil,
        remote: String? = nil,
        comparedRef: String? = nil,
        autoUpdateActive: Bool? = nil,
        latestFirstSeenAt: Date? = nil
    ) {
        self.latestCommit = latestCommit
        self.observedAt = observedAt
        self.relation = relation
        self.behindBy = behindBy
        self.remote = remote
        self.comparedRef = comparedRef
        self.autoUpdateActive = autoUpdateActive
        self.latestFirstSeenAt = latestFirstSeenAt
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
        // The three fields below only quiet or annotate a notice, so a value of
        // the wrong type reads as absent rather than losing the whole status.
        comparedRef = try? c.decodeIfPresent(String.self, forKey: .comparedRef)
        autoUpdateActive = try? c.decodeIfPresent(Bool.self, forKey: .autoUpdateActive)
        latestFirstSeenAt = try? c.decodeIfPresent(Date.self, forKey: .latestFirstSeenAt)
    }

    /// This status with `autoUpdateActive` replaced; the daemon stamps it fresh
    /// each time a status is handed out.
    public func withAutoUpdateActive(_ active: Bool) -> UpdateStatus {
        UpdateStatus(
            latestCommit: latestCommit, observedAt: observedAt, relation: relation,
            behindBy: behindBy, remote: remote, comparedRef: comparedRef,
            autoUpdateActive: active, latestFirstSeenAt: latestFirstSeenAt)
    }

    /// Nothing observed yet.
    public static let unobserved = UpdateStatus()
}
