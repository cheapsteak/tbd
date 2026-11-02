import Foundation

/// Which part of which guide line each row draws, read off the tree.
///
/// A worktree row with a worktree child owns a line: it starts in the owner's
/// own row (`startsGuide(_:)`) and runs down past its children. For each
/// worktree row above it, a row draws one of:
/// - **A branch off its parent's line** – `.branch` on every worktree child
///   but the last, `.last` on the last, where the line ends.
/// - **The line passing** – `.passing` on a row deeper in the subtree of any
///   worktree child but the last.
/// - **Nothing** – on a row in the last child's subtree, below where the line
///   ended.
///
/// Lines join worktree rows only. A group header under a worktree — a Remote
/// or Exited disclosure — and every row inside it draw no part of that
/// worktree's line, as the groups under a section header draw none: the line
/// ends at the owner's last worktree child, which the builder places before
/// its groups. A row inside such a group still draws the lines of worktrees
/// further up that pass it by.
extension SidebarTree {
    /// The lines `id`'s row draws a part of, outermost owner first, each with
    /// the owner's level and the row's role in it.
    func guideRuns(of id: SidebarNodeID) -> [SidebarGuideLine.Run] {
        var runs: [SidebarGuideLine.Run] = []
        var child = id
        var current = parent(of: id)
        while let ancestor = current {
            if case .worktree = ancestor, let owner = node(ancestor),
               let run = Self.run(of: owner, through: child, toward: id) {
                runs.append(run)
            }
            child = ancestor
            current = parent(of: ancestor)
        }
        return runs.reversed()
    }

    /// Whether `id`'s row starts a line of its own: a worktree row with a
    /// worktree child the outline shows.
    func startsGuide(_ id: SidebarNodeID) -> Bool {
        guard case .worktree = id, let node = node(id), node.showsChildren else { return false }
        return node.children.contains { Self.isWorktree($0) }
    }

    /// `owner`'s line as `row` draws it, when `child` — the owner's child on
    /// the way down to `row`, or `row` itself — is one of the owner's
    /// worktree children; nil when the row draws none of it.
    private static func run(of owner: SidebarNode, through child: SidebarNodeID,
                            toward row: SidebarNodeID) -> SidebarGuideLine.Run? {
        guard case .worktree(let model) = owner.kind else { return nil }
        let worktreeChildren = owner.children.filter { isWorktree($0) }
        guard let index = worktreeChildren.firstIndex(where: { $0.id == child }) else { return nil }
        let isLast = index == worktreeChildren.count - 1
        if child == row {
            return SidebarGuideLine.Run(owner: owner.id, level: model.depth, role: isLast ? .last : .branch,
                                        continuesFade: owner.children.first?.id == row)
        }
        guard !isLast else { return nil }
        return SidebarGuideLine.Run(owner: owner.id, level: model.depth, role: .passing, continuesFade: false)
    }

    private static func isWorktree(_ node: SidebarNode) -> Bool {
        if case .worktree = node.kind { return true }
        return false
    }
}
