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
/// Only successful (non-nil) checks are recorded: a transient git failure
/// leaves no cache entry, so the next sweep retries instead of freezing on a
/// never-computed result.
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

    private var lastChecked: [UUID: Key] = [:]

    public init() {}

    /// True when the worktree has no recorded successful check for `key`
    /// (first sighting, either tip moved, or the entry was pruned).
    public func shouldCheck(worktreeID: UUID, key: Key) -> Bool {
        lastChecked[worktreeID] != key
    }

    /// Record a successful conflict check computed against `key`.
    public func markChecked(worktreeID: UUID, key: Key) {
        lastChecked[worktreeID] = key
    }

    /// Drop entries for worktrees no longer in the sweep (archived/removed),
    /// so the cache tracks only live rows.
    public func retain(worktreeIDs: Set<UUID>) {
        lastChecked = lastChecked.filter { worktreeIDs.contains($0.key) }
    }
}
