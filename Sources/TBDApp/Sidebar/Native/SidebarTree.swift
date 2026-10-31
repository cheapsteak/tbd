import Foundation

/// The stable identity of one row in the native sidebar. Every case comes
/// from an identity that already exists — worktree, session and repo UUIDs, a
/// provider's registry name, `SidebarGroupID` — so the same row keeps the same
/// ID across rebuilds, which is what lets the outline keep its row view,
/// expansion and selection when the row moves.
enum SidebarNodeID: Hashable {
    case scratchHeader
    case scratchPrompt
    case repoHeader(UUID)
    case worktree(UUID)
    case remoteSession(UUID)
    case providerHeader(String)
    case group(SidebarGroupID)
}

/// One row of the native sidebar and the rows nested under it.
struct SidebarNode: Equatable {
    let id: SidebarNodeID
    var kind: SidebarNodeKind
    var children: [SidebarNode]
    /// The model's expanded flag: a header's own state, a group's entry in
    /// `AppState.expandedSidebarGroups`, and always true for a worktree row,
    /// whose subtree never collapses.
    var isExpanded: Bool

    /// Whether the outline shows this node's children: expanded, and with
    /// some to show. `NSOutlineView` expands only an item that has children.
    var showsChildren: Bool { isExpanded && !children.isEmpty }
}

/// What a row is, carrying the `Equatable` model its cell draws. Two kinds
/// compare equal exactly when the row draws the same.
enum SidebarNodeKind: Equatable {
    case scratchHeader(SectionHeaderModel)
    case scratchPrompt
    case repoHeader(SectionHeaderModel)
    case worktree(WorktreeRowModel)
    case remoteSession(RemoteSessionRowModel)
    case providerHeader(ProviderHeaderModel)
    case groupHeader(GroupHeaderModel)

    /// The row's height class. A change to it asks the outline for
    /// `noteHeightOfRows` on that row.
    var heightClass: RowHeightClass {
        switch self {
        case .worktree(let model): model.heightClass
        case .remoteSession(let model): model.heightClass
        case .providerHeader(let model): model.heightClass
        case .groupHeader(let model): model.heightClass
        case .scratchHeader, .scratchPrompt, .repoHeader: .single
        }
    }
}

/// The whole native sidebar as a value: built from `AppState` by
/// `SidebarTreeBuilder`, diffed by `SidebarTreeDiff`, and read by the outline
/// controller as its data source. IDs are unique across the tree; the builder
/// guarantees it, and the lookups below answer for the first occurrence.
struct SidebarTree: Equatable {
    var roots: [SidebarNode] {
        didSet { index = Index(roots: roots) }
    }

    /// Where every node sits, rebuilt whenever `roots` changes, so lookups
    /// cost the tree's depth rather than its size.
    private var index: Index

    init(roots: [SidebarNode] = []) {
        self.roots = roots
        self.index = Index(roots: roots)
    }

    /// The node with `id`, or nil when the tree has none.
    func node(_ id: SidebarNodeID) -> SidebarNode? {
        guard let path = index.paths[id], let first = path.first else { return nil }
        var node = roots[first]
        for position in path.dropFirst() {
            node = node.children[position]
        }
        return node
    }

    /// The parent of `id`: nil for a root, and nil for an ID the tree does
    /// not contain — ask `contains(_:)` to tell the two apart.
    func parent(of id: SidebarNodeID) -> SidebarNodeID? {
        index.parents[id] ?? nil
    }

    func contains(_ id: SidebarNodeID) -> Bool {
        index.paths[id] != nil
    }

    /// The children of `parent`, or the roots for nil. Empty for an ID the
    /// tree does not contain.
    func children(of parent: SidebarNodeID?) -> [SidebarNode] {
        guard let parent else { return roots }
        return node(parent)?.children ?? []
    }

    /// The number of rows the outline shows for this tree: every root, and
    /// the children of every shown, expanded node. The controller compares it
    /// with the outline's `numberOfRows` after each apply.
    var visibleRowCount: Int { index.visibleRowCount }

    /// The IDs of the rows the outline shows, top to bottom.
    var visibleIDs: [SidebarNodeID] {
        var result: [SidebarNodeID] = []
        result.reserveCapacity(index.visibleRowCount)
        Self.appendVisible(roots, into: &result)
        return result
    }

    private static func appendVisible(_ nodes: [SidebarNode], into result: inout [SidebarNodeID]) {
        for node in nodes {
            result.append(node.id)
            if node.showsChildren { appendVisible(node.children, into: &result) }
        }
    }

    /// Two trees are equal when their nodes are; the index is derived.
    static func == (lhs: SidebarTree, rhs: SidebarTree) -> Bool {
        lhs.roots == rhs.roots
    }

    private struct Index {
        var paths: [SidebarNodeID: [Int]] = [:]
        var parents: [SidebarNodeID: SidebarNodeID?] = [:]
        var visibleRowCount = 0

        init(roots: [SidebarNode]) {
            add(roots, parent: nil, path: [], visible: true)
        }

        private mutating func add(_ nodes: [SidebarNode], parent: SidebarNodeID?, path: [Int], visible: Bool) {
            for (position, node) in nodes.enumerated() where paths[node.id] == nil {
                let nodePath = path + [position]
                paths[node.id] = nodePath
                parents.updateValue(parent, forKey: node.id)
                if visible { visibleRowCount += 1 }
                add(node.children, parent: node.id, path: nodePath, visible: visible && node.showsChildren)
            }
        }
    }
}
