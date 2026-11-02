import Foundation

/// A list's rows as the guide-line rules read them: the row each sits under,
/// the rows shown under each, and each row's indentation level. The outline's
/// `SidebarTree` and the dock's `DockGuideHierarchy` both conform, so the two
/// lists shape and light their lines by the one set of rules in the extension
/// below.
///
/// Worktree rows are the rows whose ID is `SidebarNodeID.worktree`: the only
/// rows that own a line and the only rows a line joins.
protocol GuideHierarchy {
    /// The row `id` sits under, or nil for a top-level row.
    func parent(of id: SidebarNodeID) -> SidebarNodeID?
    /// The rows the list shows directly under `id`, top to bottom, of every
    /// kind; none when it shows none.
    func shownChildren(of id: SidebarNodeID) -> [SidebarNodeID]
    /// `id`'s indentation level. A line runs under its owner's icon, at the
    /// owner's level.
    func level(of id: SidebarNodeID) -> Int
    /// Whether the list shows `id`.
    func isShown(_ id: SidebarNodeID) -> Bool
}

extension SidebarNodeID {
    /// Whether the row is a worktree row, which can own and join guide lines.
    var isWorktree: Bool {
        if case .worktree = self { return true }
        return false
    }
}

// MARK: Shape

/// Which part of which guide line each row draws.
///
/// A worktree row with a worktree child shown under it owns a line: it starts
/// in the owner's own row (`startsGuide(_:)`) and runs down past its worktree
/// children. For each worktree row above it, a row draws one of:
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
/// ends at the owner's last worktree child, which the outline's builder
/// places before its groups. A row inside such a group still draws the lines
/// of worktrees further up that pass it by.
extension GuideHierarchy {
    /// The lines `id`'s row draws a part of, outermost owner first, each with
    /// the owner's level and the row's role in it.
    func guideRuns(of id: SidebarNodeID) -> [SidebarGuideLine.Run] {
        var runs: [SidebarGuideLine.Run] = []
        var child = id
        var current = parent(of: id)
        while let owner = current {
            if owner.isWorktree, let run = run(of: owner, through: child, toward: id) {
                runs.append(run)
            }
            child = owner
            current = parent(of: owner)
        }
        return runs.reversed()
    }

    /// Whether `id`'s row starts a line of its own: a worktree row with a
    /// worktree child the list shows.
    func startsGuide(_ id: SidebarNodeID) -> Bool {
        id.isWorktree && shownChildren(of: id).contains { $0.isWorktree }
    }

    /// `owner`'s line as `row` draws it, when `child` — the owner's child on
    /// the way down to `row`, or `row` itself — is one of the owner's
    /// worktree children; nil when the row draws none of it. The fade carries
    /// on into the row shown directly under the owner.
    private func run(of owner: SidebarNodeID, through child: SidebarNodeID,
                     toward row: SidebarNodeID) -> SidebarGuideLine.Run? {
        let shown = shownChildren(of: owner)
        let worktreeChildren = shown.filter { $0.isWorktree }
        guard let index = worktreeChildren.firstIndex(of: child) else { return nil }
        let isLast = index == worktreeChildren.count - 1
        if child == row {
            return SidebarGuideLine.Run(owner: owner, level: level(of: owner), role: isLast ? .last : .branch,
                                        continuesFade: shown.first == row)
        }
        guard !isLast else { return nil }
        return SidebarGuideLine.Run(owner: owner, level: level(of: owner), role: .passing, continuesFade: false)
    }
}

// MARK: Focus

/// Which guide lines draw active: the line a focus row — the hovered row, or
/// a selected worktree row — draws a branch of, or starts.
///
/// A focus row lights only a line it is joined to by the shape rules above,
/// so what lights is always drawn through the row:
/// - **A worktree row that starts a line** — its worktree children show
///   under it — lights its own, the one down its children.
/// - **Any other worktree row whose parent is a worktree** lights its
///   parent's line, the one it branches off or ends in.
/// - **Every other row** lights nothing: a top-level worktree row that starts
///   no line, a worktree row whose only worktree descendants sit in a group
///   under it, a row inside a Remote or Exited group (lines never cross a
///   group header), a header, a group header, a remote session and the
///   scratch prompt.
extension GuideHierarchy {
    /// The worktree whose guide line `focus` lights, or nil when it lights
    /// none. See the extension's rule.
    func activeGuideAncestor(of focus: SidebarNodeID) -> SidebarNodeID? {
        guard focus.isWorktree else { return nil }
        if startsGuide(focus) { return focus }
        guard let parent = parent(of: focus), parent.isWorktree else { return nil }
        return parent
    }

    /// The active ancestors of every focus row the list shows. A focus row
    /// out of view — a selected row inside a collapsed section or group, or
    /// one the dock does not show — lights nothing.
    func activeGuideAncestors(of focus: some Sequence<SidebarNodeID>) -> Set<SidebarNodeID> {
        var active: Set<SidebarNodeID> = []
        for id in focus where isShown(id) {
            if let ancestor = activeGuideAncestor(of: id) { active.insert(ancestor) }
        }
        return active
    }
}
