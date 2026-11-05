import Foundation

/// The outline's tree as the guide-line rules read it (`GuideHierarchy`): a
/// node's shown children are its children while it shows them, and its
/// level is its model's depth, which counts the group headers above it.
extension SidebarTree: GuideHierarchy {
    func shownChildren(of id: SidebarNodeID) -> [SidebarNodeID] {
        guard let node = node(id), node.showsChildren else { return [] }
        return node.children.map(\.id)
    }

    func level(of id: SidebarNodeID) -> Int {
        guard let kind = node(id)?.kind else { return 0 }
        switch kind {
        case .worktree(let model): return model.depth
        case .remoteSession(let model): return model.depth
        case .groupHeader(let model): return model.depth
        case .scratchHeader, .scratchPrompt, .repoHeader, .providerHeader, .addRepository: return 0
        }
    }
}
