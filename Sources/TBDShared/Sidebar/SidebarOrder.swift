import Foundation

extension Worktree {
    /// The order of one set of siblings, the daemon's: `sortOrder`, then
    /// `createdAt`, then ID. `worktree.moveMany` renumbers a group in this
    /// order, so every list that shows a group sorts it this way too: rows
    /// that tie on `sortOrder` then show where the first move into their
    /// group leaves them, instead of in whatever order the sort met them.
    public static func precedesSibling(_ lhs: Worktree, _ rhs: Worktree) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// The sidebar's worktree order as pure functions, shared by the app's
/// `AppState` and any other consumer that must list rows the way the sidebar
/// does.
public enum SidebarOrder {
    /// Where a depth-first walk lists a row against its nested worktrees.
    public enum Walk: Sendable {
        /// The row, then its nested worktrees: the order the sidebar shows.
        case parentsFirst
        /// Its nested worktrees, then the row: the order a selection's
        /// archive runs in, since a worktree cannot be archived while a
        /// nested one is active.
        case childrenFirst
    }

    /// Recursion cap, mirroring `SidebarTreeBuilder.maxSubtreeDepth`, in case
    /// a cyclic parent chain ever makes it into in-memory state.
    public static let maxDepth = 50

    /// Active and creating rows with a parent, grouped by parent, each group
    /// in sibling order (`Worktree.precedesSibling`).
    public static func childrenIndex(_ worktrees: some Sequence<Worktree>) -> [UUID: [Worktree]] {
        var index: [UUID: [Worktree]] = [:]
        for worktree in worktrees {
            guard let parentID = worktree.parentWorktreeID,
                  worktree.status == .active || worktree.status == .creating else { continue }
            index[parentID, default: []].append(worktree)
        }
        // `Array(index.keys)` rather than `index.keys`: the lazy view holds a
        // reference to the dictionary's storage, so mutating `index` inside
        // the loop would force a full copy-on-write copy on every iteration.
        for key in Array(index.keys) {
            index[key]?.sort(by: Worktree.precedesSibling)
        }
        return index
    }

    /// One repo's walk: its `.main` row (if any), then its top-level active
    /// and creating rows in sibling order, each followed (or preceded, for
    /// `.childrenFirst`) depth-first by its nested worktrees from `children`,
    /// which may name rows of other repos. Depth is 0 for a top-level row.
    public static func walk(
        repoWorktrees: [Worktree], children: [UUID: [Worktree]], order: Walk
    ) -> [(worktree: Worktree, depth: Int)] {
        var result: [(worktree: Worktree, depth: Int)] = []
        // Main row first (if present in this repo).
        if let main = repoWorktrees.first(where: { $0.status == .main }) {
            result.append((main, 0))
        }
        // Top-level active/creating worktrees in this repo, in sibling order.
        let topLevel = repoWorktrees
            .filter { ($0.status == .active || $0.status == .creating) && $0.parentWorktreeID == nil }
            .sorted(by: Worktree.precedesSibling)
        for worktree in topLevel {
            appendSubtree(worktree, depth: 0, order: order, children: children, into: &result)
        }
        return result
    }

    private static func appendSubtree(
        _ worktree: Worktree, depth: Int, order: Walk, children: [UUID: [Worktree]],
        into result: inout [(worktree: Worktree, depth: Int)]
    ) {
        if order == .parentsFirst { result.append((worktree, depth)) }
        if depth < maxDepth {
            for child in children[worktree.id] ?? [] {
                appendSubtree(child, depth: depth + 1, order: order, children: children, into: &result)
            }
        }
        if order == .childrenFirst { result.append((worktree, depth)) }
    }
}
