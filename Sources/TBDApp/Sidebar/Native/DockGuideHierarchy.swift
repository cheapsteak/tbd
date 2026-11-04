import Foundation

/// The dock's rows as the guide-line rules read them (`GuideHierarchy`), so
/// the dock shapes its lines by the outline's rules. Built when the dock's
/// rows' IDs or depths change.
///
/// The rows are a preorder walk of each pinned subtree with a depth per row,
/// so a row's parent is the nearest row above it one level up, and a row's
/// level is its depth. A pinned root, and a remote pin after them, sit at
/// depth 0 under nothing. The dock has no group headers.
///
/// The dock's builder makes neither of the two shapes below, and the reading
/// stays sound if rows ever arrive in one:
/// - **A gap in the depths** – a row more than one level deeper than the row
///   above it sits directly under that row, as though one level deeper, and
///   the rows after it read it at that level. Its own level, where its
///   content and its line sit, stays its depth.
/// - **An ID that repeats** – every lookup answers for its first row. A later
///   row with it keeps its level's place on the way down, but names no
///   parent, so the rows under it sit under no row rather than under its
///   first row or one further up.
struct DockGuideHierarchy: GuideHierarchy {
    /// Each row's index in the rows, an ID's first when it repeats: what the
    /// controller reads a row's cached lines by.
    private(set) var indices: [SidebarNodeID: Int] = [:]
    private var depths: [Int] = []
    private var parents: [SidebarNodeID: SidebarNodeID] = [:]
    private var children: [SidebarNodeID: [SidebarNodeID]] = [:]

    init(rows: [DockRow]) {
        depths = rows.map(\.depth)
        // The rows on the way down to the current one, the row at level `k`
        // at index `k`, nil where a repeated ID holds the level. Cut back to
        // a row's level, the path ends in the row's parent.
        var path: [SidebarNodeID?] = []
        for (index, row) in rows.enumerated() {
            let level = min(max(row.depth, 0), path.count)
            path.removeSubrange(level...)
            guard indices[row.id] == nil else {
                path.append(nil)
                continue
            }
            indices[row.id] = index
            if let above = path.last, let parent = above {
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
}
