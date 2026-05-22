import Foundation
import TBDShared

extension AppState {
    /// How long a tombstone survives without daemon confirmation before it is
    /// force-evicted. Generous: a stuck or failed archive recovers its row
    /// after this window rather than vanishing permanently.
    nonisolated static let archiveTombstoneTTL: TimeInterval = 30

    /// Returns the tombstones that should still be kept. A tombstone is evicted
    /// when the daemon confirms the archive (worktree reported `.archived` or
    /// absent) or when it has outlived `archiveTombstoneTTL`.
    ///
    /// - Parameter daemonWorktrees: the raw, unfiltered worktree list from the
    ///   daemon (includes `.archived` rows).
    nonisolated static func reconcileTombstones(
        _ tombstones: [UUID: Date],
        daemonWorktrees: [Worktree],
        now: Date,
        ttl: TimeInterval = AppState.archiveTombstoneTTL
    ) -> [UUID: Date] {
        var statusByID: [UUID: WorktreeStatus] = [:]
        for wt in daemonWorktrees { statusByID[wt.id] = wt.status }
        return tombstones.filter { id, createdAt in
            switch statusByID[id] {
            case .archived, .none:
                return false                          // daemon confirmed gone
            default:
                return now.timeIntervalSince(createdAt) < ttl   // keep until TTL
            }
        }
    }

    /// Filters daemon worktrees down to what the sidebar should treat as
    /// present: drops `.archived` rows and any tombstoned ID.
    nonisolated static func visibleWorktrees(
        from daemonWorktrees: [Worktree],
        tombstones: Set<UUID>
    ) -> [Worktree] {
        daemonWorktrees.filter { $0.status != .archived && !tombstones.contains($0.id) }
    }
}
