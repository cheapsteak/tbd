import Foundation

/// TTL cache for the per-branch git facts the PR poll needs: the upstream
/// (tracking) branch name, and the branch `@{push}` resolves to.
///
/// `GitManager.upstreamBranchName` and `GitManager.pushBranchName` each shell
/// out on every call. `pr.list` invokes them once per worktree on every poll,
/// so under a poll storm the daemon spawns dozens of concurrent subprocesses.
///
/// There is NO daemon-side FileWatcher and `GitManager` is a stateless struct,
/// so this cache cannot invalidate on filesystem git events — it relies on a
/// short TTL (default 60s) to bound staleness. The upstream tracking config is
/// only mutated outside the daemon (e.g. when the user pushes with `-u`), so a
/// 60s window is an acceptable lag for PR-list enrichment.
///
/// `nil` results (a branch with no upstream) are cached too; the TTL bounds how
/// long a freshly-pushed branch waits before its upstream is observed.
actor BranchTrackingCache {
    private struct Entry {
        let value: String?
        let fetchedAt: Date
    }

    private struct PushEntry {
        let value: GitManager.PushBranchResolution
        let fetchedAt: Date
    }

    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    private var pushEntries: [String: PushEntry] = [:]

    /// - Parameters:
    ///   - ttl: How long a cached value stays fresh, in seconds.
    ///   - now: Clock seam for tests; defaults to wall-clock `Date()`.
    init(ttl: TimeInterval = 60, now: @Sendable @escaping () -> Date = { Date() }) {
        self.ttl = ttl
        self.now = now
    }

    private func key(worktreePath: String, branch: String) -> String {
        // NUL delimiter so one worktree path can't be a prefix of another's key.
        "\(worktreePath)\u{0}\(branch)"
    }

    /// Return the cached upstream branch name if fresh, otherwise call `fetch`,
    /// store the result (including `nil`), and return it.
    func upstreamBranchName(
        worktreePath: String,
        branch: String,
        fetch: @Sendable () async -> String?
    ) async -> String? {
        let k = key(worktreePath: worktreePath, branch: branch)
        if let entry = entries[k], now().timeIntervalSince(entry.fetchedAt) < ttl {
            return entry.value
        }
        let value = await fetch()
        entries[k] = Entry(value: value, fetchedAt: now())
        return value
    }

    /// Return the cached `@{push}` resolution if fresh, otherwise call `fetch`
    /// and store the result.
    ///
    /// `.lookupFailed` is cached like any other value: a caller must treat it as
    /// "no evidence" regardless of age, so a stale one is never acted upon, and
    /// re-running a failing subprocess on every poll of a poll storm is exactly
    /// what this cache exists to prevent.
    func pushBranch(
        worktreePath: String,
        branch: String,
        fetch: @Sendable () async -> GitManager.PushBranchResolution
    ) async -> GitManager.PushBranchResolution {
        let k = key(worktreePath: worktreePath, branch: branch)
        if let entry = pushEntries[k], now().timeIntervalSince(entry.fetchedAt) < ttl {
            return entry.value
        }
        let value = await fetch()
        pushEntries[k] = PushEntry(value: value, fetchedAt: now())
        return value
    }

    /// Drop all cached entries for a worktree path (any branch).
    func invalidate(worktreePath: String) {
        let prefix = "\(worktreePath)\u{0}"
        for k in entries.keys where k.hasPrefix(prefix) {
            entries.removeValue(forKey: k)
        }
        for k in pushEntries.keys where k.hasPrefix(prefix) {
            pushEntries.removeValue(forKey: k)
        }
    }

    /// Drop every cached entry.
    func invalidateAll() {
        entries.removeAll()
        pushEntries.removeAll()
    }

    /// Drop cached entries whose (worktreePath, branch) is not in `active`,
    /// bounding the cache to currently-active worktree branches so entries for
    /// archived/removed worktrees don't leak across a long-lived daemon.
    func retain(active: [(worktreePath: String, branch: String)]) {
        let keep = Set(active.map { key(worktreePath: $0.worktreePath, branch: $0.branch) })
        entries = entries.filter { keep.contains($0.key) }
        pushEntries = pushEntries.filter { keep.contains($0.key) }
    }
}
