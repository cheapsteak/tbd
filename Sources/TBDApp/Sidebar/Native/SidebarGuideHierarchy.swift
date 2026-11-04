import Foundation

/// A list's rows as the guide-line rules read them: the row each sits under,
/// the rows shown under each, and each row's indentation level. The outline's
/// `SidebarTree` and the dock's `DockGuideHierarchy` both conform, so the two
/// lists shape their lines by the one set of rules in the extension below.
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

    /// `id`'s row's lines, as a list keeps them: the guides of its runs
    /// (`guideRuns(of:)`), and whether it starts its own.
    func rowGuides(of id: SidebarNodeID) -> SidebarGuideLine.RowGuides {
        SidebarGuideLine.RowGuides(guides: SidebarGuideLine.guides(for: guideRuns(of: id)),
                                   startsGuide: startsGuide(id))
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
