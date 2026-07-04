import Foundation

/// Dirty gate for the periodic conflict sweep (`refreshGitStatuses`).
///
/// The conflict answer for a worktree depends on exactly two commits: the tip
/// of the worktree's branch and the tip of `origin/<defaultBranch>`. If that
/// pair is unchanged since the last successful check, re-running
/// `git merge-base --is-ancestor` (and on divergence `git merge-tree`) cannot
/// produce a different answer — so the sweep skips those subprocesses entirely.
/// Resolving the pair costs one `git for-each-ref` per repo per sweep, instead
/// of 1-2 subprocesses per worktree per sweep.
///
/// Entries are scoped by repo because the sweep runs per repo in a loop over
/// all repos: pruning must only ever touch the repo being swept, or repo B's
/// sweep would evict repo A's fresh entries and the gate would never engage
/// on multi-repo installs.
///
/// Only successful (non-nil) checks whose result was persisted are recorded: a
/// transient git or DB failure leaves no cache entry, so the next sweep
/// retries instead of freezing on a never-stored result.
public actor ConflictSweepCache {
    /// The pair of commits a conflict check was computed against.
    public struct Key: Hashable, Sendable {
        /// Tip SHA of the worktree's branch.
        public let branchTip: String
        /// Tip SHA of `origin/<defaultBranch>`.
        public let baseTip: String

        public init(branchTip: String, baseTip: String) {
            self.branchTip = branchTip
            self.baseTip = baseTip
        }
    }

    /// repoID → (worktreeID → last successfully checked pair).
    private var lastChecked: [UUID: [UUID: Key]] = [:]

    public init() {}

    /// True when the worktree has no recorded successful check for `key`
    /// (first sighting, either tip moved, or the entry was pruned).
    public func shouldCheck(repoID: UUID, worktreeID: UUID, key: Key) -> Bool {
        lastChecked[repoID]?[worktreeID] != key
    }

    /// Record a successful, persisted conflict check computed against `key`.
    public func markChecked(repoID: UUID, worktreeID: UUID, key: Key) {
        lastChecked[repoID, default: [:]][worktreeID] = key
    }

    /// Drop this repo's entries for worktrees no longer in its sweep
    /// (archived/removed). Other repos' entries are untouched.
    public func retain(repoID: UUID, worktreeIDs: Set<UUID>) {
        lastChecked[repoID] = lastChecked[repoID]?.filter { worktreeIDs.contains($0.key) }
    }
}
