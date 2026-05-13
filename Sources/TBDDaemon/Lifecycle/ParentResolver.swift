import Foundation
import TBDShared

/// Resolves a worktree's parent at create time, following the order:
/// 1. `suppressAutoParent` → nil (flat)
/// 2. explicit parent (validated: exists, not `main`, not `archived`) — throws
///    on invalid
/// 3. `siblingOf` X → X.parentWorktreeID — silent fallback to nil when X is
///    missing or X itself is archived (the resolved grandparent might still be
///    valid, but treating archived siblings as "not a valid spawn point" is
///    safer than producing an invisible child)
/// 4. `caller` (validated: exists, not `main`, not `archived`) — silent
///    fallback to nil otherwise
/// 5. nil
///
/// Archived parents are rejected because the sidebar's `topLevelWorktrees`
/// filter excludes children (regardless of the child's own status), and
/// `WorktreeSubtreeView` never descends into an archived parent's subtree —
/// so a newly-created child of an archived row would be invisible until a
/// reconcile pass nulls its parent pointer.
public enum ParentResolver {
    public static func resolve(
        db: TBDDatabase,
        explicitParent: UUID?,
        siblingOf: UUID?,
        caller: UUID?,
        suppressAutoParent: Bool
    ) async throws -> UUID? {
        if suppressAutoParent { return nil }

        if let pid = explicitParent {
            guard let p = try await db.worktrees.get(id: pid) else {
                throw WorktreeMoveError.parentNotFound
            }
            if p.status == .main { throw WorktreeMoveError.parentIsMain }
            if p.status == .archived { throw WorktreeMoveError.parentIsArchived }
            return pid
        }

        if let sid = siblingOf {
            guard let s = try await db.worktrees.get(id: sid) else {
                return nil
            }
            if s.status == .archived { return nil }
            return s.parentWorktreeID
        }

        if let cid = caller {
            guard let c = try await db.worktrees.get(id: cid) else { return nil }
            if c.status == .main { return nil }
            if c.status == .archived { return nil }
            return cid
        }

        return nil
    }
}
