import Foundation

/// Which guide lines draw active: the line a focus row — the hovered row, or
/// a selected worktree row — draws a branch of, or starts.
///
/// A focus row lights only a line it is joined to by the shape rules
/// (`guideRuns(of:)`, `startsGuide(_:)`), so what lights is always drawn
/// through the row:
/// - **A worktree row that starts a line** — its worktree children show
///   under it — lights its own, the one down its children.
/// - **Any other worktree row whose parent is a worktree** lights its
///   parent's line, the one it branches off or ends in.
/// - **Every other row** lights nothing: a top-level worktree row that starts
///   no line, a worktree row whose only worktree descendants sit in a group
///   under it, a row inside a Remote or Exited group (lines never cross a
///   group header), a header, a group header, a remote session and the
///   scratch prompt.
extension SidebarTree {
    /// The worktree whose guide line `focus` lights, or nil when it lights
    /// none. See the extension's rule.
    func activeGuideAncestor(of focus: SidebarNodeID) -> SidebarNodeID? {
        guard case .worktree = focus else { return nil }
        if startsGuide(focus) { return focus }
        guard let parent = parent(of: focus), case .worktree = parent else { return nil }
        return parent
    }

    /// The active ancestors of every focus row the outline shows. A focus row
    /// out of view — a selected row inside a collapsed section or group —
    /// lights nothing.
    func activeGuideAncestors(of focus: some Sequence<SidebarNodeID>) -> Set<SidebarNodeID> {
        var active: Set<SidebarNodeID> = []
        for id in focus where isShown(id) {
            if let ancestor = activeGuideAncestor(of: id) { active.insert(ancestor) }
        }
        return active
    }

    /// Whether the outline shows `id`: it is in the tree, and every node
    /// above it shows its children.
    func isShown(_ id: SidebarNodeID) -> Bool {
        guard contains(id) else { return false }
        var current = parent(of: id)
        while let ancestor = current {
            guard node(ancestor)?.showsChildren == true else { return false }
            current = parent(of: ancestor)
        }
        return true
    }
}
