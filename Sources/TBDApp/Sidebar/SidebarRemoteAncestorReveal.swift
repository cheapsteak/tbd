import Foundation
import TBDShared

extension SidebarRemoteGroups.Snapshot {
    /// Root-first path through known parents, bounded like the subtree renderer.
    /// Missing parents, cycles and paths past the cap cannot name a visible owner.
    func ancestorPath(to id: UUID) -> [Worktree]? {
        var path: [Worktree] = []
        var seen: Set<UUID> = []
        var next: UUID? = id
        while let current = next {
            guard path.count <= 50, seen.insert(current).inserted,
                  let row = rowsByID[current] else { return nil }
            path.append(row)
            next = row.parentWorktreeID
        }
        return path.reversed()
    }

    /// Reveal every disclosure on an existing rendered ownership path. Scratch
    /// and main rows currently render without child trees; this does not invent
    /// groups for those unrendered hierarchies or change repository filtering.
    func parentRevealGroups(worktreeIDs: Set<UUID>, remoteID: UUID?, repoIDs: Set<UUID>) -> Set<SidebarGroupID> {
        var targets = worktreeIDs
        if let remoteID { targets.formUnion(rowIDsBySession[remoteID] ?? []) }
        var result: Set<SidebarGroupID> = []
        var partitions: [UUID: SidebarRemoteGroups] = [:]
        for target in targets {
            guard let path = ancestorPath(to: target), let root = path.first,
                  let repoID = root.repoID, repoIDs.contains(repoID),
                  root.status == .active || root.status == .creating,
                  path.allSatisfy({ $0.status == .active || $0.status == .creating }) else { continue }
            for parent in path.dropLast() {
                let groups: SidebarRemoteGroups
                if let cached = partitions[parent.id] {
                    groups = cached
                } else {
                    groups = SidebarRemoteGroups(
                        roots: children[parent.id] ?? [], remainder: [], snapshot: self, unread: [:])
                    partitions[parent.id] = groups
                }
                result.formUnion(groups.revealGroups(
                    owner: .parent(parent.id), worktreeIDs: [target], remoteID: nil))
            }
        }
        return result
    }
}
