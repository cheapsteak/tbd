import Foundation

/// Reports when a worktree's remote-tracking tip (`origin/<branch>`) moves.
///
/// The local tip is deliberately ignored: agents commit far more often than
/// they push, and a PR check before the push is wasted.
///
/// A first sighting is a baseline, never a change — after a daemon restart the
/// watch has no earlier value to compare against, and the tier timers already
/// cover the PR. A missing remote ref (never pushed, or pushed elsewhere) is no
/// signal and leaves the recorded tip alone; a branch's first push, which
/// creates `origin/<branch>` after the watch saw it absent, is a change.
public struct RemoteTipWatch: Sendable {
    private var seen: [UUID: String?] = [:]

    public init() {}

    /// True exactly once per change of the worktree's remote-tracking tip.
    public mutating func observe(worktreeID: UUID, remoteTip: String?) -> Bool {
        guard let previous = seen[worktreeID] else {
            seen[worktreeID] = remoteTip
            return false
        }
        guard let remoteTip else { return false }
        seen[worktreeID] = remoteTip
        return previous != remoteTip
    }

    /// Forget every worktree not in `ids`.
    public mutating func retain(_ ids: Set<UUID>) {
        seen = seen.filter { ids.contains($0.key) }
    }
}

/// The sweep-facing wrapper around `RemoteTipWatch`. `refreshGitStatuses`
/// hands it the `origin/<branch>` tips it already resolves, so the trigger
/// costs no subprocess. `onMoved` is wired by `Daemon` to
/// `PRPollScheduler.trigger(worktreeID:)`.
public actor RemoteTipTracker {
    private var watch = RemoteTipWatch()
    private var byRepo: [UUID: Set<UUID>] = [:]
    private var onMoved: (@Sendable (UUID) async -> Void)?

    public init() {}

    public func setOnMoved(_ cb: @escaping @Sendable (UUID) async -> Void) { onMoved = cb }

    public func observe(worktreeID: UUID, remoteTip: String?) async {
        if watch.observe(worktreeID: worktreeID, remoteTip: remoteTip) {
            await onMoved?(worktreeID)
        }
    }

    /// Scoped per repo, like `BranchTipTracker.retain`: a sweep over one repo
    /// must not forget another repo's worktrees.
    public func retain(repoID: UUID, worktreeIDs: Set<UUID>) {
        byRepo[repoID] = worktreeIDs
        watch.retain(byRepo.values.reduce(into: Set<UUID>()) { $0.formUnion($1) })
    }
}
