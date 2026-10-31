import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "native-sidebar")

/// A `worktree.moveMany` the app has applied locally and not yet retired.
///
/// It stays in `AppState.pendingWorktreeMoves` until its RPC has succeeded and
/// the app has applied either the `worktreeSiblingsReordered` delta carrying
/// its `moveID` (whichever of the delta and the reply came first) or a
/// worktree fetch numbered at or above its `fence`. Until then every fetch
/// result and every move delta is re-based on it, so a fetch that read the
/// daemon before the commit, or another writer's delta, cannot put the rows
/// back where they were.
struct PendingWorktreeMove: Equatable {
    let moveID: UUID
    /// The carried rows, in top-to-bottom order.
    let worktreeIDs: [UUID]
    /// nil = the top level of the carried rows' own group.
    let newParentID: UUID?
    /// nil = the end of the destination group.
    let before: UUID?
    /// The number the next worktree fetch would get when the RPC succeeded.
    /// A fetch numbered at or above it was sent after the commit and so reads
    /// it. nil until the RPC succeeds.
    var fence: UInt64?
    var rpcSucceeded: Bool
    /// Whether the delta carrying this move's `moveID` has been applied.
    var deltaApplied: Bool
}

extension AppState {
    // MARK: - Moving worktrees

    /// Moves `ids` under `newParentID` (nil: the top level of their own
    /// group), before `before` (nil: at the end), and returns the move's ID.
    ///
    /// The rows move here first, with the same `SiblingPlacement.place` the
    /// daemon runs, before any message leaves the app. The move then stays in
    /// `pendingWorktreeMoves` while `worktree.moveMany` is in flight. If the
    /// RPC fails, the carried rows and the groups they left and joined go back
    /// to how they stood at the drop, every other row keeps whatever changed
    /// meanwhile, the app refreshes from the daemon, and a toast names the row
    /// and the reason.
    @discardableResult
    func moveWorktrees(ids: [UUID], newParentID: UUID?, before: UUID?) -> UUID {
        let moveID = UUID()
        guard !ids.isEmpty else { return moveID }
        let move = PendingWorktreeMove(
            moveID: moveID, worktreeIDs: ids, newParentID: newParentID, before: before,
            fence: nil, rpcSucceeded: false, deltaApplied: false)

        var lists = WorktreeMoveLists(worktrees: worktrees, scratch: scratchWorktrees)
        let snapshot = lists.snapshot(for: move)
        let name = lists.row(ids[0])?.displayName ?? "worktree"
        lists.apply(move)
        pendingWorktreeMoves.append(move)
        assignWorktreeLists(lists.result)

        logger.debug(
            "worktree.moveMany \(moveID, privacy: .public): \(ids.count, privacy: .public) row(s) under \(newParentID?.uuidString ?? "top level", privacy: .public) before \(before?.uuidString ?? "end", privacy: .public)")
        let params = WorktreeMoveManyParams(
            moveID: moveID, worktreeIDs: ids, newParentID: newParentID, beforeWorktreeID: before)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.worktreeMoveManySender(params)
                self.worktreeMoveSucceeded(moveID)
            } catch {
                await self.worktreeMoveFailed(moveID, snapshot: snapshot, name: name, error: error)
            }
        }
        return moveID
    }

    /// The RPC replied, so the daemon has committed the move. Fetches sent
    /// from now on read the commit; anything sent earlier is fenced off.
    private func worktreeMoveSucceeded(_ moveID: UUID) {
        guard let index = pendingWorktreeMoves.firstIndex(where: { $0.moveID == moveID }) else { return }
        let fence = nextWorktreeFetchNumber
        pendingWorktreeMoves[index].rpcSucceeded = true
        pendingWorktreeMoves[index].fence = fence
        worktreeFetchFence = max(fence, worktreeFetchFence)
        retireSettledWorktreeMoves()
    }

    private func worktreeMoveFailed(
        _ moveID: UUID, snapshot: WorktreeMoveSnapshot, name: String, error: any Error
    ) async {
        logger.error(
            "worktree.moveMany \(moveID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        pendingWorktreeMoves.removeAll { $0.moveID == moveID }
        // Restore only the rows the move touched, then put back any other
        // move still in flight. The snapshot is what stands if the daemon is
        // unreachable and the refresh below fails too.
        var lists = WorktreeMoveLists(worktrees: worktrees, scratch: scratchWorktrees)
        lists.restore(snapshot)
        for move in pendingWorktreeMoves { lists.apply(move) }
        assignWorktreeLists(lists.result)
        await refreshWorktrees()
        showTransientToast("Couldn't move \(name): \(error.localizedDescription)", style: .error)
    }

    /// Drops every pending move whose RPC succeeded and whose result the app
    /// has applied from the daemon: its own delta, or the fetch numbered
    /// `appliedFetch` when that is at or above the move's fence.
    func retireSettledWorktreeMoves(appliedFetch: UInt64? = nil) {
        pendingWorktreeMoves.removeAll { move in
            guard move.rpcSucceeded else { return false }
            if move.deltaApplied { return true }
            guard let appliedFetch, let fence = move.fence else { return false }
            return appliedFetch >= fence
        }
    }

    /// Applies a committed `worktree.moveMany`'s destination group: each row
    /// the app lists takes the daemon's parent and `sortOrder`. Rows the app
    /// does not list (archived ones) are skipped.
    func applyWorktreeSiblingsReorderedDelta(_ delta: WorktreeSiblingsReorderedDelta) {
        if let moveID = delta.moveID,
           let index = pendingWorktreeMoves.firstIndex(where: { $0.moveID == moveID }) {
            pendingWorktreeMoves[index].deltaApplied = true
        }
        retireSettledWorktreeMoves()
        var lists = WorktreeMoveLists(worktrees: worktrees, scratch: scratchWorktrees)
        lists.apply(delta.entries)
        // Another writer's group predates this app's moves still in flight,
        // so those are re-applied on top of it.
        for move in pendingWorktreeMoves { lists.apply(move) }
        assignWorktreeLists(lists.result)
    }

    /// Assigns each list only when it changed, so an overlay that lands where
    /// the app already is publishes nothing.
    func assignWorktreeLists(_ lists: (worktrees: [UUID: [Worktree]], scratch: [Worktree])) {
        if lists.worktrees != worktrees {
            worktrees = lists.worktrees
        }
        if lists.scratch != scratchWorktrees {
            scratchWorktrees = lists.scratch
        }
    }

    /// `worktrees` and `scratch` with each move in `moves` applied, in order.
    ///
    /// For each move: the destination group is the children of `newParentID`
    /// across every repo, or, for the top level, the rows with no parent in
    /// the carried rows' own repo (the scratch rows when that is nil), other
    /// than `main`. The carried rows take the new parent and the group is
    /// renumbered 0…n−1 in `SiblingPlacement.place` order, which is what the
    /// daemon writes. Rows keep their positions in the arrays, except that the
    /// scratch list is re-sorted by `sortOrder` when a move touched it.
    ///
    /// A move leaves the lists as they are when a carried row is missing, when
    /// the daemon would refuse it (carrying `main`, nesting a scratch row, a
    /// parent cycle, top-level rows from different groups), or when the group
    /// already stands in the move's order with the carried rows in it. That
    /// last case is a state that already holds the move (its own delta, or a
    /// fetch made after the commit), and leaving it alone keeps the daemon's
    /// numbers, which count rows the app does not list.
    nonisolated static func applyingMoves(
        _ moves: [PendingWorktreeMove],
        worktrees: [UUID: [Worktree]],
        scratch: [Worktree]
    ) -> (worktrees: [UUID: [Worktree]], scratch: [Worktree]) {
        guard !moves.isEmpty else { return (worktrees, scratch) }
        var lists = WorktreeMoveLists(worktrees: worktrees, scratch: scratch)
        for move in moves {
            lists.apply(move)
        }
        return lists.result
    }
}

/// What a failed move restores: the carried rows' parents, and the
/// `sortOrder` of every row in the groups they left and the group they
/// joined, as they stood at the drop.
private struct WorktreeMoveSnapshot: Sendable {
    var parents: [UUID: UUID?] = [:]
    var sortOrders: [UUID: Int] = [:]
}

/// One set of siblings, as the daemon's `moveMany` defines it.
private enum WorktreeSiblingGroup: Hashable {
    /// The children of one row, across every repo.
    case children(of: UUID)
    /// The rows with no parent in one repo, or among the scratch rows when
    /// `repoID` is nil, other than `main`.
    case topLevel(repoID: UUID?)

    /// The group `row` sits in now.
    init(containing row: Worktree) {
        if let parentID = row.parentWorktreeID {
            self = .children(of: parentID)
        } else {
            self = .topLevel(repoID: row.repoID)
        }
    }

    func contains(_ row: Worktree) -> Bool {
        switch self {
        case .children(let parentID):
            return row.parentWorktreeID == parentID
        case .topLevel(let repoID):
            return row.parentWorktreeID == nil && row.repoID == repoID && row.status != .main
        }
    }
}

/// A working copy of the app's two worktree lists, with every row's position
/// indexed so a move can find and rewrite rows by ID in place.
private struct WorktreeMoveLists {
    private enum Slot {
        case repo(UUID, Int)
        case scratch(Int)
    }

    private(set) var worktrees: [UUID: [Worktree]]
    private(set) var scratch: [Worktree]
    private var scratchChanged = false
    private var slots: [UUID: Slot] = [:]

    init(worktrees: [UUID: [Worktree]], scratch: [Worktree]) {
        self.worktrees = worktrees
        self.scratch = scratch
        for (repoID, rows) in worktrees {
            for (index, row) in rows.enumerated() {
                slots[row.id] = .repo(repoID, index)
            }
        }
        for (index, row) in scratch.enumerated() {
            slots[row.id] = .scratch(index)
        }
    }

    /// Both lists, the scratch one sorted by `sortOrder` as `refreshWorktrees`
    /// sorts it, when a row in it changed.
    var result: (worktrees: [UUID: [Worktree]], scratch: [Worktree]) {
        (worktrees, scratchChanged ? scratch.sorted { $0.sortOrder < $1.sortOrder } : scratch)
    }

    func row(_ id: UUID) -> Worktree? {
        guard let slot = slots[id] else { return nil }
        switch slot {
        case .repo(let repoID, let index):
            return worktrees[repoID]?[index]
        case .scratch(let index):
            return scratch[index]
        }
    }

    private mutating func update(_ id: UUID, _ change: (inout Worktree) -> Void) {
        guard let slot = slots[id] else { return }
        switch slot {
        case .repo(let repoID, let index):
            guard var updated = worktrees[repoID]?[index] else { return }
            change(&updated)
            worktrees[repoID]?[index] = updated
        case .scratch(let index):
            change(&scratch[index])
            scratchChanged = true
        }
    }

    /// The listed rows of `group`, in the daemon's sibling order: `sortOrder`,
    /// then `createdAt`, then ID.
    private func siblingIDs(in group: WorktreeSiblingGroup) -> [UUID] {
        var members: [Worktree] = []
        for rows in worktrees.values {
            members.append(contentsOf: rows.filter { group.contains($0) })
        }
        members.append(contentsOf: scratch.filter { group.contains($0) })
        members.sort { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return members.map(\.id)
    }

    /// The group `move` places its rows in, or nil when it cannot be applied:
    /// a carried row is not listed, or the daemon would refuse the move.
    private func destination(of move: PendingWorktreeMove) -> WorktreeSiblingGroup? {
        let carried = move.worktreeIDs.compactMap { row($0) }
        guard let first = carried.first, carried.count == move.worktreeIDs.count,
              carried.allSatisfy({ $0.status != .main }) else { return nil }
        if let parentID = move.newParentID {
            guard carried.allSatisfy({ $0.repoID != nil }),
                  !closesCycle(parentID: parentID, carried: Set(move.worktreeIDs)) else { return nil }
            return .children(of: parentID)
        }
        guard carried.allSatisfy({ $0.repoID == first.repoID }) else { return nil }
        return .topLevel(repoID: first.repoID)
    }

    /// Whether nesting the carried rows under `parentID` would make a row its
    /// own ancestor. A parent chain that already loops counts as a cycle.
    private func closesCycle(parentID: UUID, carried: Set<UUID>) -> Bool {
        var visited = Set<UUID>()
        var next: UUID? = parentID
        while let id = next {
            if carried.contains(id) || !visited.insert(id).inserted { return true }
            next = row(id)?.parentWorktreeID
        }
        return false
    }

    mutating func apply(_ move: PendingWorktreeMove) {
        guard let group = destination(of: move) else { return }
        let members = siblingIDs(in: group)
        let ordered = SiblingPlacement.place(group: members, carried: move.worktreeIDs, before: move.before)
        guard ordered != members else { return }
        let carried = Set(move.worktreeIDs)
        for (sortOrder, id) in ordered.enumerated() {
            update(id) { row in
                if carried.contains(id) {
                    row.parentWorktreeID = move.newParentID
                }
                row.sortOrder = sortOrder
            }
        }
    }

    mutating func apply(_ entries: [WorktreeOrderEntry]) {
        for entry in entries {
            update(entry.worktreeID) { row in
                row.parentWorktreeID = entry.parentWorktreeID
                row.sortOrder = entry.sortOrder
            }
        }
    }

    func snapshot(for move: PendingWorktreeMove) -> WorktreeMoveSnapshot {
        var taken = WorktreeMoveSnapshot()
        var groups = Set<WorktreeSiblingGroup>()
        for id in move.worktreeIDs {
            guard let carried = self.row(id) else { continue }
            taken.parents.updateValue(carried.parentWorktreeID, forKey: id)
            groups.insert(WorktreeSiblingGroup(containing: carried))
        }
        if let destination = destination(of: move) {
            groups.insert(destination)
        }
        for group in groups {
            for id in siblingIDs(in: group) {
                taken.sortOrders[id] = self.row(id)?.sortOrder
            }
        }
        return taken
    }

    mutating func restore(_ snapshot: WorktreeMoveSnapshot) {
        for (id, parent) in snapshot.parents {
            update(id) { $0.parentWorktreeID = parent }
        }
        for (id, sortOrder) in snapshot.sortOrders {
            update(id) { $0.sortOrder = sortOrder }
        }
    }
}
