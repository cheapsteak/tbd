import AppKit

// What a drag in the native sidebar carries, and what a drop proposal means.
// Pure: everything here reads a `SidebarTree` and nothing else, and answers
// in worktree IDs, never row indices, so an answer still names the right rows
// after a daemon push moves them.
// Spec: docs/specs/2026-10-31-native-sidebar-design.md, "Drag and drop".

/// The worktree IDs one sidebar drag carries, in top-to-bottom tree order.
/// The pasteboard holds one item per carried row (see
/// `NSPasteboard.PasteboardType.tbdSidebarWorktrees`); this is the drag's
/// value once those items are read back.
struct SidebarDragPayload: Codable, Equatable {
    let worktreeIDs: [UUID]
}

extension NSPasteboard.PasteboardType {
    /// One carried sidebar row's worktree ID. Each carried row is its own
    /// `NSPasteboardItem` under this private, in-process type, and the drop
    /// reads every item.
    static var tbdSidebarWorktrees: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType("com.github.cheapsteak.tbd.sidebar-worktree")
    }

    /// One pinned dock row. A type of its own, so rows never cross between
    /// the dock and the main list.
    static var tbdDockPin: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType("com.github.cheapsteak.tbd.dock-pin")
    }
}

/// What a drop does. `worktree.moveMany` takes it as it is: a nest is
/// `newParentID: id, beforeWorktreeID: nil`, a place maps field for field.
enum SidebarDropDecision: Equatable {
    /// Nest the carried rows as the last children of this worktree, in their
    /// top-to-bottom order. Their subtrees move with them.
    case nest(under: UUID)
    /// Place the carried rows among `parent`'s children — nil is the top
    /// level of the rows' own group — before the row `before`, or at the end
    /// of the group when `before` is nil.
    case place(parent: UUID?, before: UUID?)
    case reject
}

/// Decides what a drag proposal in the native sidebar means.
///
/// `validateDrop` hands it the outline's proposal — a parent item and a child
/// index, or `dropOnItemIndex` for "onto the item" — and the pointer's depth;
/// `acceptDrop` asks again against an index of the tree current at the
/// drop. The answer carries a retarget only when the position it chose
/// differs from the one proposed, for `setDropItem(_:dropChildIndex:)`.
///
/// Every rule applies to every carried row; if one fails, the drop is
/// rejected. A decision reads only the nodes on the ancestor paths of the
/// rows and positions it asks about, through the `SidebarDropIndex` the
/// caller builds once per tree, so it costs the tree's depth, not its size.
enum SidebarDropPolicy {
    /// `NSOutlineViewDropOnItemIndex`: a proposal onto an item rather than
    /// between its children.
    static let dropOnItemIndex = -1

    /// An outline position: a parent item (nil for the roots) and a child
    /// index, `dropOnItemIndex` meaning onto the parent itself.
    typealias Retarget = (parent: SidebarNodeID?, childIndex: Int)
    typealias Answer = (decision: SidebarDropDecision, retarget: Retarget?)

    private static var rejected: Answer { (.reject, nil) }

    // MARK: Pointer

    /// The visual depth the pointer's x names: one level per indentation
    /// step, counted from `inset`, where a depth-0 row's content starts.
    static func pointerDepth(x: CGFloat, inset: CGFloat) -> Int {
        let steps = ((x - inset) / SidebarNativeMetrics.indentation).rounded()
        guard steps.isFinite else { return 0 }
        return Int(min(max(steps, -64), 64))
    }

    // MARK: What a drag carries

    /// The rows a drag starting on `origin` carries, top to bottom.
    ///
    /// A drag from a selected row carries the selection; from an unselected
    /// row, that row alone. Main rows, unadopted remote sessions and headers
    /// stay behind, as does a row whose ancestor is also carried, since it
    /// travels with that ancestor. A selection that mixes scratch rows and
    /// worktrees carries the kind of `origin`. Nothing is carried when
    /// `origin` itself cannot be dragged.
    static func carried(selection: [SidebarNodeID], origin: SidebarNodeID, index: SidebarDropIndex) -> [UUID] {
        guard let originRow = CarriedRow(origin, index: index) else { return [] }
        let candidates = selection.contains(origin) ? selection : [origin]
        var rows: [CarriedRow] = []
        var ids: Set<SidebarNodeID> = []
        for id in candidates where !ids.contains(id) {
            guard let row = CarriedRow(id, index: index), row.isScratch == originRow.isScratch else { continue }
            rows.append(row)
            ids.insert(id)
        }
        let tops = rows.filter { !hasAncestor($0, in: ids, index: index) }
        let ordered = tops
            .map { (row: $0, path: index.path(to: $0.id) ?? []) }
            .sorted { $0.path.lexicographicallyPrecedes($1.path) }
        return ordered.map { $0.row.uuid }
    }

    private static func hasAncestor(_ row: CarriedRow, in ids: Set<SidebarNodeID>, index: SidebarDropIndex) -> Bool {
        var next = row.parent
        while let id = next {
            if ids.contains(id) { return true }
            next = index.entry(id)?.parent
        }
        return false
    }

    // MARK: Where it can go

    /// What dropping `carried` at the proposed position does, and the
    /// position the outline should show instead when that differs.
    ///
    /// `pointerDepth` is the pointer's visual depth (`pointerDepth(x:inset:)`).
    /// It decides the gap below a subtree's last row, which can mean the end
    /// of that subtree's children or any shallower level: the policy clamps
    /// it between the visual depths of the rows below and above the gap and
    /// ignores the level the outline proposed, which reads raw x against raw
    /// outline levels and so lags this sidebar's depth by one. A proposal
    /// between two sections reads as the end of the section above.
    static func resolve(carried: [UUID], proposedParent: SidebarNodeID?, childIndex: Int,
                        pointerDepth: Int, index: SidebarDropIndex) -> Answer {
        guard let rows = CarriedRows(carried, index: index) else { return rejected }
        if childIndex == dropOnItemIndex {
            guard let target = proposedParent else { return rejected }
            return onto(target, rows: rows, index: index)
        }
        guard let gap = canonicalGap(parent: proposedParent, childIndex: childIndex,
                                     pointerDepth: pointerDepth, index: index) else { return rejected }
        return place(under: gap.parent, at: gap.childIndex, rows: rows,
                     proposal: (proposedParent, childIndex), index: index)
    }

    /// A drop onto a row. A worktree row nests the carried rows as its last
    /// children; the main row un-nests them to the top of its repo's
    /// worktrees, directly below it. Every other row rejects: nesting under
    /// a scratch row, a remote session or a header is not a thing.
    ///
    /// State groups are closed both ways: a row inside a group nests only
    /// onto a row in that same group, and a row outside every group nests
    /// onto no row inside one.
    private static func onto(_ targetID: SidebarNodeID, rows: CarriedRows, index: SidebarDropIndex) -> Answer {
        guard let target = index.entry(targetID), case .worktree(let model) = target.node.kind,
              case .worktree(let targetUUID) = targetID else { return rejected }
        if model.isMain {
            guard let sectionID = target.parent, let section = index.entry(sectionID) else { return rejected }
            return place(under: sectionID, at: section.rowGaps.lowerBound, rows: rows,
                         proposal: (targetID, dropOnItemIndex), index: index)
        }
        guard let lineage = trace(from: target, carried: rows.ids, index: index),
              !lineage.isCollapsed, !lineage.isCarried,
              !rows.isScratch, lineage.section != .scratchHeader else { return rejected }
        for row in rows.rows {
            if lineage.group != row.lineage.group { return rejected }
            // Nesting onto the rows' current parent only moves them among
            // their current siblings, which another repo's section allows.
            if !row.isNative(to: lineage.section), row.parent != targetID { return rejected }
        }
        return (.nest(under: targetUUID), nil)
    }

    /// A drop at child `proposedIndex` of `parentID`, the gap
    /// `canonicalGap` chose.
    ///
    /// A gap above the main row, or past a parent's worktree rows — among the
    /// remote sessions and group headers that follow them — moves to the
    /// nearest gap a worktree can take: directly below main, or directly
    /// after the last worktree row.
    private static func place(under parentID: SidebarNodeID, at proposedIndex: Int, rows: CarriedRows,
                              proposal: Retarget, index: SidebarDropIndex) -> Answer {
        guard let parent = index.entry(parentID),
              let lineage = trace(from: parent, carried: rows.ids, index: index),
              !lineage.isCollapsed, !lineage.isCarried,
              // Scratch rows reorder within the scratch section only, and no
              // other row drops into it.
              (lineage.section == .scratchHeader) == rows.isScratch else { return rejected }
        switch parent.node.kind {
        case .scratchHeader, .repoHeader, .providerHeader, .groupHeader:
            break
        case .worktree:
            // Scratch rows render flat.
            if rows.isScratch { return rejected }
        case .remoteSession, .scratchPrompt:
            return rejected
        }
        for row in rows.rows {
            // A row's state decides which group renders it, so state groups
            // are closed: a gap inside a group takes only the rows that came
            // from it, and a row inside a group goes to no gap outside it.
            if lineage.group != row.lineage.group { return rejected }
            // Another repo's section takes only a reorder among the rows'
            // current siblings.
            if !row.isNative(to: lineage.section), row.parent != parentID { return rejected }
        }
        let gaps = parent.rowGaps
        let childIndex = min(max(proposedIndex, gaps.lowerBound), gaps.upperBound)
        // The daemon places before a row that is not itself carried.
        var before: UUID?
        var position = childIndex
        while position < gaps.upperBound {
            let child = index.child(of: parent, at: position)
            if !rows.ids.contains(child.id), case .worktree(let uuid) = child.id {
                before = uuid
                break
            }
            position += 1
        }
        let answer: Retarget = (parentID, childIndex)
        let unchanged = proposal.parent == answer.parent && proposal.childIndex == answer.childIndex
        return (.place(parent: lineage.owner, before: before), unchanged ? nil : answer)
    }

    // MARK: The gap a proposal names

    /// The gap a between-rows proposal points at, as the node the rows would
    /// land under and an index among its children.
    ///
    /// `NSOutlineView` names the gap below a subtree's last row in several
    /// ways, one per level the subtree ends, and picks among them from raw x.
    /// So the proposal is used only to find the rows above and below the gap;
    /// the pointer's depth, clamped between theirs, picks the level. Between
    /// two sections the row below is the next header, and the gap reads as
    /// the end of the section above, down to its top level.
    private static func canonicalGap(parent: SidebarNodeID?, childIndex: Int, pointerDepth: Int,
                                     index: SidebarDropIndex) -> (parent: SidebarNodeID, childIndex: Int)? {
        guard childIndex >= 0 else { return nil }
        let above: SidebarDropIndex.Entry
        // The shallowest outline level the gap can mean.
        let shallowest: Int
        if let parent {
            guard let entry = index.entry(parent) else { return nil }
            let count = entry.node.showsChildren ? entry.node.children.count : 0
            guard childIndex <= count else { return nil }
            if childIndex > 0 {
                guard let last = lastVisible(index.child(of: entry, at: childIndex - 1).id, index: index)
                else { return nil }
                above = last
            } else {
                above = entry
            }
            shallowest = childIndex < count ? entry.level + 1 : levelBelowSubtree(of: entry, index: index)
        } else {
            guard childIndex > 0, childIndex <= index.rootCount,
                  let last = lastVisible(index.root(at: childIndex - 1).id, index: index) else { return nil }
            above = last
            shallowest = 1
        }
        // Outline level is visual depth plus one.
        let deepest = max(shallowest, above.level)
        let level = min(max(pointerDepth, shallowest - 1), deepest - 1) + 1
        // Deeper than the row above: the gap opens that row's children.
        if level > above.level { return (above.node.id, 0) }
        // Otherwise the rows land right after the row above's ancestor at
        // that level.
        var anchor = above
        while anchor.level > level {
            guard let parentID = anchor.parent, let next = index.entry(parentID) else { return nil }
            anchor = next
        }
        guard let landing = anchor.parent else { return nil }
        return (landing, anchor.position + 1)
    }

    /// The last row the outline shows in `id`'s subtree: `id` itself when it
    /// shows no children.
    private static func lastVisible(_ id: SidebarNodeID, index: SidebarDropIndex) -> SidebarDropIndex.Entry? {
        guard var current = index.entry(id) else { return nil }
        while current.node.showsChildren, let last = current.node.children.last {
            // A level that does not deepen means a corrupt tree; stop rather
            // than loop.
            guard let next = index.entry(last.id), next.level == current.level + 1 else { return nil }
            current = next
        }
        return current
    }

    /// The outline level of the first row below `entry`'s subtree — its next
    /// sibling's, or its nearest ancestor's next sibling's — or 1 when the
    /// subtree ends its section, since the end of a section reads as the
    /// section's own top level.
    private static func levelBelowSubtree(of entry: SidebarDropIndex.Entry, index: SidebarDropIndex) -> Int {
        var current = entry
        while let parentID = current.parent, let parent = index.entry(parentID) {
            if current.position + 1 < parent.node.children.count { return current.level }
            current = parent
        }
        return 1
    }

    // MARK: Lineage

    /// What one walk from a node up to its section header finds.
    private struct Lineage {
        /// The section header the walk ends at.
        var section: SidebarNodeID
        /// The nearest group header, the node itself included: the state
        /// group that renders the node.
        var group: SidebarNodeID?
        /// The nearest worktree row, the node itself included: the parent a
        /// row placed among this node's children gets. Nil at a section's
        /// top level, and in a group that sits directly under a section.
        var owner: UUID?
        /// The node or an ancestor hides its children.
        var isCollapsed: Bool
        /// The node or an ancestor is carried.
        var isCarried: Bool

        /// Folds in `node`, the next one up the walk.
        mutating func note(_ node: SidebarNode, carried: Set<SidebarNodeID>) {
            section = node.id
            if carried.contains(node.id) { isCarried = true }
            switch node.kind {
            case .groupHeader:
                if group == nil { group = node.id }
                if !node.isExpanded { isCollapsed = true }
            case .worktree:
                if owner == nil, case .worktree(let uuid) = node.id { owner = uuid }
                if !node.isExpanded { isCollapsed = true }
            case .scratchHeader, .repoHeader, .providerHeader:
                if !node.isExpanded { isCollapsed = true }
            case .remoteSession, .scratchPrompt:
                break
            }
        }
    }

    /// Walks from `start` up to its section header; nil when the chain of
    /// parents breaks.
    private static func trace(from start: SidebarDropIndex.Entry, carried: Set<SidebarNodeID>,
                              index: SidebarDropIndex) -> Lineage? {
        var lineage = Lineage(section: start.node.id, group: nil, owner: nil, isCollapsed: false, isCarried: false)
        lineage.note(start.node, carried: carried)
        var current = start
        while let parentID = current.parent {
            guard let next = index.entry(parentID) else { return nil }
            lineage.note(next.node, carried: carried)
            current = next
        }
        return lineage
    }

    // MARK: Carried rows

    /// One draggable row and where it sits.
    private struct CarriedRow {
        let id: SidebarNodeID
        let uuid: UUID
        let parent: SidebarNodeID?
        let lineage: Lineage
        /// The repo the row belongs to; nil for a scratch row.
        let homeRepoID: UUID?

        var isScratch: Bool { lineage.section == .scratchHeader }

        /// Nil unless `id` is a draggable row in the tree: a worktree row,
        /// local or an adopted remote lane, other than a main row.
        init?(_ id: SidebarNodeID, index: SidebarDropIndex) {
            guard case .worktree(let uuid) = id, let entry = index.entry(id),
                  case .worktree(let model) = entry.node.kind, !model.isMain,
                  let lineage = SidebarDropPolicy.trace(from: entry, carried: [], index: index) else { return nil }
            self.id = id
            self.uuid = uuid
            self.parent = entry.parent
            self.lineage = lineage
            self.homeRepoID = model.homeRepoID
        }

        /// Whether `section` is the row's own: its repo's section, or — for
        /// the Scratch section and the Remote section's provider sections,
        /// which belong to no repo — the section it renders in.
        func isNative(to section: SidebarNodeID) -> Bool {
            if case .repoHeader(let repoID) = section { return homeRepoID == repoID }
            return lineage.section == section
        }
    }

    /// The rows a drop moves. Nil unless every ID is a draggable row the
    /// tree still has — a row archived during the drag rejects the drop —
    /// and all are one kind, scratch or not.
    private struct CarriedRows {
        let rows: [CarriedRow]
        let ids: Set<SidebarNodeID>
        let isScratch: Bool

        init?(_ carried: [UUID], index: SidebarDropIndex) {
            var rows: [CarriedRow] = []
            for uuid in carried {
                guard let row = CarriedRow(.worktree(uuid), index: index) else { return nil }
                rows.append(row)
            }
            guard let first = rows.first,
                  rows.allSatisfy({ $0.isScratch == first.isScratch }) else { return nil }
            self.rows = rows
            self.ids = Set(rows.map(\.id))
            self.isScratch = first.isScratch
        }
    }
}

/// Where every node of one `SidebarTree` sits — its parent, its position
/// among its siblings, its outline level — so a drop decision reads only the
/// nodes on the paths it asks about instead of walking the tree. The caller
/// builds one per tree and keeps it while the tree stands: a drag asks about
/// one tree many times a second.
struct SidebarDropIndex {
    struct Entry {
        let node: SidebarNode
        let parent: SidebarNodeID?
        /// The node's position among its parent's children, or the roots.
        let position: Int
        /// Outline level: 0 for a section header. A row's visual depth is
        /// its level minus one.
        let level: Int
        /// The child indices a worktree row can be placed at: after a leading
        /// main row or scratch prompt, through the end of the worktree rows,
        /// which come before any remote session or group header.
        let rowGaps: ClosedRange<Int>
    }

    /// Counts the nodes a decision reads: the seam the test that bounds a
    /// decision's cost by the tree's depth reads.
    final class ReadCounter {
        var count = 0

        init() {}
    }

    let tree: SidebarTree
    private let entries: [SidebarNodeID: Entry]
    private let counter: ReadCounter?

    init(tree: SidebarTree, counter: ReadCounter? = nil) {
        var entries: [SidebarNodeID: Entry] = [:]
        SidebarDropIndex.add(tree.roots, parent: nil, level: 0, into: &entries)
        self.tree = tree
        self.entries = entries
        self.counter = counter
    }

    /// Indexes `nodes` and their subtrees. As `SidebarTree` does, the first
    /// occurrence of an ID wins and a repeat is skipped with its subtree.
    private static func add(_ nodes: [SidebarNode], parent: SidebarNodeID?, level: Int,
                            into entries: inout [SidebarNodeID: Entry]) {
        for (position, node) in nodes.enumerated() where entries[node.id] == nil {
            entries[node.id] = Entry(node: node, parent: parent, position: position, level: level,
                                     rowGaps: rowGaps(among: node.children))
            add(node.children, parent: node.id, level: level + 1, into: &entries)
        }
    }

    private static func rowGaps(among children: [SidebarNode]) -> ClosedRange<Int> {
        var start = 0
        while start < children.count, isLead(children[start].kind) { start += 1 }
        var end = start
        while end < children.count, isRow(children[end].kind) { end += 1 }
        return start...end
    }

    /// A child that heads its parent's rows and takes no row above it.
    private static func isLead(_ kind: SidebarNodeKind) -> Bool {
        switch kind {
        case .worktree(let model): model.isMain
        case .scratchPrompt: true
        default: false
        }
    }

    /// A worktree row other than a main row.
    private static func isRow(_ kind: SidebarNodeKind) -> Bool {
        if case .worktree(let model) = kind { return !model.isMain }
        return false
    }

    // MARK: Reads — each counts one node

    /// The entry for `id`, or nil when the tree has none.
    func entry(_ id: SidebarNodeID) -> Entry? {
        counter?.count += 1
        return entries[id]
    }

    /// The child at `position` among `entry`'s children.
    func child(of entry: Entry, at position: Int) -> SidebarNode {
        counter?.count += 1
        return entry.node.children[position]
    }

    var rootCount: Int { tree.roots.count }

    func root(at position: Int) -> SidebarNode {
        counter?.count += 1
        return tree.roots[position]
    }

    /// The positions from a root down to `id`, which order rows top to
    /// bottom; nil when the tree has no such node.
    func path(to id: SidebarNodeID) -> [Int]? {
        guard var current = entry(id) else { return nil }
        var reversedPath = [current.position]
        while let parentID = current.parent {
            guard let next = entry(parentID) else { return nil }
            reversedPath.append(next.position)
            current = next
        }
        return Array(reversedPath.reversed())
    }
}
