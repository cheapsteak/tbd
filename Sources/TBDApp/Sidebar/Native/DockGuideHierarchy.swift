import Foundation

/// The dock's rows as the guide-line rules read them (`GuideHierarchy`), so
/// the dock shapes and lights its lines by the outline's rules. Built once
/// per apply.
///
/// The rows are a preorder walk of each pinned subtree with a depth per row,
/// so a row's parent is the nearest row above it one level up, and a row's
/// level is its depth. A pinned root, and a remote pin after them, sit at
/// depth 0 under nothing. The dock has no group headers.
struct DockGuideHierarchy: GuideHierarchy {
    /// Each row's index in the rows: what the controller reads a row's
    /// height and cached lines by.
    private(set) var indices: [SidebarNodeID: Int] = [:]
    private var depths: [Int] = []
    private var parents: [SidebarNodeID: SidebarNodeID] = [:]
    private var children: [SidebarNodeID: [SidebarNodeID]] = [:]

    init(rows: [DockRow]) {
        depths = rows.map(\.depth)
        // The rows on the way down to the current one, one per depth.
        var path: [SidebarNodeID] = []
        for (index, row) in rows.enumerated() where indices[row.id] == nil {
            indices[row.id] = index
            let depth = max(row.depth, 0)
            if depth < path.count {
                path.removeSubrange(depth...)
            }
            if depth > 0, depth == path.count, let parent = path.last {
                parents[row.id] = parent
                children[parent, default: []].append(row.id)
            }
            path.append(row.id)
        }
    }

    func parent(of id: SidebarNodeID) -> SidebarNodeID? {
        parents[id]
    }

    func shownChildren(of id: SidebarNodeID) -> [SidebarNodeID] {
        children[id] ?? []
    }

    func level(of id: SidebarNodeID) -> Int {
        indices[id].map { depths[$0] } ?? 0
    }

    /// Every dock row shows: the dock has nothing to collapse.
    func isShown(_ id: SidebarNodeID) -> Bool {
        indices[id] != nil
    }
}
