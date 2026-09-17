import Foundation
import TBDShared

/// A presentation-only partition of existing roots. Descendants keep their
/// parent, order, and row identity; the shelf moves whole subtrees.
struct SidebarHibernationPartition {
    let workingRoots: [Worktree]
    let hibernatedRoots: [Worktree]
    /// Includes descendants, so counts and navigation describe every row in
    /// the shelf rather than just the roots or their terminal inventories.
    let hibernatedWorktreeIDs: Set<UUID>

    var hibernatedCount: Int { hibernatedWorktreeIDs.count }
}

enum SidebarHibernation {
    /// Matches WorktreeSubtreeView's maximum rendered nesting depth. Beyond
    /// this bound the inventory is uncertain, so keep the root in place.
    static let maximumDepth = 50

    /// Call with the repository's existing ordered top-level rows, or the
    /// Scratch section's rows. The child lookup remains the same one used by
    /// the ordinary tree and pinned dock; this projection never filters it.
    /// Missing and empty terminal inventories are both insufficient evidence.
    static func partition(
        roots: [Worktree],
        terminals: [UUID: [Terminal]],
        allowsDescendants: Bool = true,
        children: (UUID) -> [Worktree]
    ) -> SidebarHibernationPartition {
        var workingRoots: [Worktree] = []
        var hibernatedRoots: [Worktree] = []
        var hibernatedIDs: Set<UUID> = []

        for root in roots {
            if let ids = parkedSubtreeIDs(
                root: root, terminals: terminals, allowsDescendants: allowsDescendants, children: children
            ) {
                hibernatedRoots.append(root)
                hibernatedIDs.formUnion(ids)
            } else {
                workingRoots.append(root)
            }
        }
        return SidebarHibernationPartition(
            workingRoots: workingRoots,
            hibernatedRoots: hibernatedRoots,
            hibernatedWorktreeIDs: hibernatedIDs)
    }

    private static func parkedSubtreeIDs(
        root: Worktree,
        terminals: [UUID: [Terminal]],
        allowsDescendants: Bool,
        children: (UUID) -> [Worktree]
    ) -> Set<UUID>? {
        // A caller must not extract a parked child from its working parent.
        guard root.parentWorktreeID == nil else { return nil }
        var pending: [(worktree: Worktree, depth: Int)] = [(root, 0)]
        var visited: Set<UUID> = []
        while let (worktree, depth) = pending.popLast() {
            guard depth <= maximumDepth,
                  visited.insert(worktree.id).inserted,
                  worktree.status == .active,
                  worktree.archivedAt == nil,
                  worktree.location.isLocal,
                  !worktree.isNightwatchDesk,
                  let inventory = terminals[worktree.id],
                  !inventory.isEmpty,
                  inventory.allSatisfy({ $0.worktreeID == worktree.id && $0.isParked })
            else { return nil }

            let descendants = children(worktree.id)
            // Scratch currently renders flat rows. Keep a root with children
            // in place rather than count or reveal rows that cannot mount.
            guard allowsDescendants || descendants.isEmpty else { return nil }
            guard descendants.allSatisfy({ $0.parentWorktreeID == worktree.id }) else { return nil }
            pending.append(contentsOf: descendants.map { ($0, depth + 1) })
        }
        return visited
    }
}
