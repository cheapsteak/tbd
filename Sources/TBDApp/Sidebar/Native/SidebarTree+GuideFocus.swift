import Foundation

/// Which guide lines draw active: the group a focus row — the hovered row, or
/// a selected worktree row — is in.
///
/// A guide line belongs to a worktree row and runs down past its children
/// (`guideRuns(of:)`). A focus row lights the line of its *active ancestor*:
/// - **A worktree row whose subtree shows a worktree row** — a child, or one
///   inside an expanded group under it — lights its own line, the one down
///   its children.
/// - **Any other worktree row** lights its nearest worktree ancestor's line,
///   the one down it and its siblings. That covers a leaf, and a row whose
///   only worktree descendants sit in a collapsed group, which show none.
/// - **A top-level worktree row with nothing shown under it, a header, a
///   group header, a remote session or the scratch prompt** lights nothing.
extension SidebarTree {
    /// The worktree rows `id` sits under, outermost first. Group headers
    /// between them are skipped.
    func worktreeAncestors(of id: SidebarNodeID) -> [SidebarNodeID] {
        var ancestors: [SidebarNodeID] = []
        var current = parent(of: id)
        while let ancestor = current {
            if case .worktree = ancestor { ancestors.append(ancestor) }
            current = parent(of: ancestor)
        }
        return ancestors.reversed()
    }

    /// The worktree whose guide line `focus` lights, or nil when it lights
    /// none. See the extension's rule.
    func activeGuideAncestor(of focus: SidebarNodeID) -> SidebarNodeID? {
        guard case .worktree = focus, let node = node(focus) else { return nil }
        if Self.showsWorktreeDescendant(node) { return focus }
        return worktreeAncestors(of: focus).last
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

    /// Whether the outline shows a worktree row under `node`: a child, or one
    /// inside an expanded group.
    private static func showsWorktreeDescendant(_ node: SidebarNode) -> Bool {
        guard node.showsChildren else { return false }
        for child in node.children {
            if case .worktree = child.kind { return true }
            if showsWorktreeDescendant(child) { return true }
        }
        return false
    }
}
