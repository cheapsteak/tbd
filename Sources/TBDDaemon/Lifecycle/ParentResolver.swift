import Foundation
import TBDShared

/// Resolves a worktree's parent at create time, following the order:
/// 1. `suppressAutoParent` → nil (flat)
/// 2. explicit parent (validated: exists, not `main`) — throws on invalid
/// 3. `siblingOf` X → X.parentWorktreeID (nil if X is top-level or missing)
/// 4. `caller` (validated: exists, not `main`; nil fallback if missing or main)
/// 5. nil
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
            return pid
        }

        if let sid = siblingOf {
            guard let s = try await db.worktrees.get(id: sid) else {
                return nil
            }
            return s.parentWorktreeID
        }

        if let cid = caller {
            guard let c = try await db.worktrees.get(id: cid) else { return nil }
            if c.status == .main { return nil }
            return cid
        }

        return nil
    }
}
