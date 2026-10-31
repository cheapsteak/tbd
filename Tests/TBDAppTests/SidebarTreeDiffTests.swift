import Foundation
import Testing
@testable import TBDApp

// Tier 1: pure values, no AppKit. Every case replays the diff's steps on
// `OutlineSimulator` and checks the result against an outline loaded fresh
// with the new tree.

/// `SidebarTreeDiff`: whole-tree diffs whose replayed steps converge.
/// Spec: docs/specs/2026-10-31-native-sidebar-design.md, "Update loop".
@Suite("Sidebar tree diff")
struct SidebarTreeDiffTests {
    @Test func reversal() {
        let old = Self.tree([Self.node(1), Self.node(2), Self.node(3), Self.node(4)])
        let new = Self.tree([Self.node(4), Self.node(3), Self.node(2), Self.node(1)])
        let update = Self.converge(old, new).update
        #expect(!update.steps.isEmpty)
        #expect(update.steps.allSatisfy { if case .move = $0 { return true } else { return false } },
                "A reorder moves rows; it never removes and reinserts them")
    }

    @Test func crossParentMoveIsAMoveNotRemoveInsert() {
        let old = Self.tree([
            Self.node(1, [Self.node(10), Self.node(11)]),
            Self.node(2, [Self.node(20)]),
        ])
        let new = Self.tree([
            Self.node(1, [Self.node(10)]),
            Self.node(2, [Self.node(11), Self.node(20)]),
        ])
        let result = Self.converge(old, new)
        let moved = Self.id(11)
        #expect(result.update.steps == [
            .move(fromParent: Self.id(1), fromIndex: 1, toParent: Self.id(2), toIndex: 0),
        ])
        #expect(!result.applied.removed.contains(moved))
        #expect(!result.applied.inserted.contains(moved))
    }

    /// The moved row carries its subtree, expansion included.
    @Test func crossParentMoveCarriesItsSubtree() {
        let old = Self.tree([
            Self.node(1, [Self.node(10, [Self.node(100), Self.node(101)])]),
            Self.node(2, [Self.node(20)]),
        ])
        let new = Self.tree([
            Self.node(1, []),
            Self.node(2, [Self.node(20), Self.node(10, [Self.node(100), Self.node(101)])]),
        ])
        let result = Self.converge(old, new)
        let subtree = [Self.id(10), Self.id(100), Self.id(101)]
        #expect(result.applied.removed.allSatisfy { !subtree.contains($0) })
        #expect(result.applied.inserted.allSatisfy { !subtree.contains($0) })
        #expect(!result.update.steps.contains(.expand(Self.id(10))),
                "The subtree arrives expanded with its row; it is not expanded again")
    }

    @Test func moveUnderCollapsedParentIsSkipped() {
        let old = Self.tree([
            Self.node(1, [Self.node(10), Self.node(11)], expanded: false),
            Self.node(2, [Self.node(20)]),
        ])
        // A reorder entirely under a collapsed parent asks nothing of the outline.
        let reordered = Self.tree([
            Self.node(1, [Self.node(11), Self.node(10)], expanded: false),
            Self.node(2, [Self.node(20)]),
        ])
        #expect(Self.converge(old, reordered).update.steps.isEmpty)

        // Out from under a collapsed parent: the outline never loaded the row,
        // so it is inserted where it lands, with no call under the collapsed one.
        let outOf = Self.tree([
            Self.node(1, [Self.node(10)], expanded: false),
            Self.node(2, [Self.node(11), Self.node(20)]),
        ])
        #expect(Self.converge(old, outOf).update.steps == [.insert(parent: Self.id(2), index: 0, id: Self.id(11))])

        // Into a collapsed parent: the row leaves; the parent loads it on expand.
        let into = Self.tree([
            Self.node(1, [Self.node(10), Self.node(11), Self.node(20)], expanded: false),
            Self.node(2, []),
        ])
        let update = Self.converge(old, into).update
        #expect(!update.steps.contains { Self.isUnder(Self.id(1), $0) })
    }

    @Test func leafGainingChildReloadsThenExpands() {
        let old = Self.tree([Self.node(1), Self.node(2)])
        let new = Self.tree([Self.node(1, [Self.node(10)]), Self.node(2)])
        let update = Self.converge(old, new).update
        #expect(update.steps == [.reloadItem(Self.id(1)), .expand(Self.id(1))])
    }

    @Test func insertedParentExpandsInsteadOfChildInserts() {
        let old = Self.tree([Self.node(1)])
        let new = Self.tree([Self.node(1), Self.node(2, [Self.node(20), Self.node(21, [Self.node(210)])])])
        let update = Self.converge(old, new).update
        #expect(update.steps == [
            .insert(parent: nil, index: 1, id: Self.id(2)),
            .expand(Self.id(2)),
            .expand(Self.id(21)),
        ])
    }

    @Test func contentOnlyChangeReconfigures() {
        let old = Self.tree([Self.node(1, [Self.node(10, name: "before")]), Self.node(2)])
        let new = Self.tree([Self.node(1, [Self.node(10, name: "after")]), Self.node(2)])
        let update = Self.converge(old, new).update
        #expect(update.steps.isEmpty)
        #expect(update.reconfigure == [Self.id(10)])
        #expect(update.heightChanged.isEmpty)
    }

    @Test func heightClassChangeReported() {
        let old = Self.tree([Self.node(1), Self.node(2, height: .single)])
        let new = Self.tree([Self.node(1), Self.node(2, height: .withSubtitle)])
        let update = Self.converge(old, new).update
        #expect(update.steps.isEmpty)
        #expect(update.reconfigure == [Self.id(2)])
        #expect(update.heightChanged == [Self.id(2)])
    }

    /// A Remote group that loses its last row disappears while the row moves
    /// back inline: the row keeps its view, and only the group is removed.
    @Test func removedContainerKeepsItsSurvivingRowAsAMove() {
        let group = SidebarNodeID.group(SidebarGroupID(owner: .repository(Self.uuid(1)), kind: .remote))
        let old = Self.tree([
            SidebarNode(id: .repoHeader(Self.uuid(1)), kind: Self.row("repo"), children: [
                Self.node(10),
                SidebarNode(id: group, kind: Self.row("group"), children: [Self.node(11)], isExpanded: true),
            ], isExpanded: true),
        ])
        let new = Self.tree([
            SidebarNode(id: .repoHeader(Self.uuid(1)), kind: Self.row("repo"),
                        children: [Self.node(10), Self.node(11)], isExpanded: true),
        ])
        let result = Self.converge(old, new)
        #expect(!result.applied.removed.contains(Self.id(11)))
        #expect(!result.applied.inserted.contains(Self.id(11)))
        #expect(result.applied.removed == [group], "Only the emptied group leaves")
    }

    @Test func modelCollapseAndExpand() {
        let open = Self.tree([Self.node(1, [Self.node(10, [Self.node(100)])]), Self.node(2)])
        let closed = Self.tree([Self.node(1, [Self.node(10, [Self.node(100)])], expanded: false), Self.node(2)])
        #expect(Self.converge(open, closed).update.steps == [.collapse(Self.id(1))])
        // Expanding again reloads the subtree from the data source, nested
        // expansion included.
        #expect(Self.converge(closed, open).update.steps == [.expand(Self.id(1)), .expand(Self.id(10))])
    }

    @Test func seededRandomTreesConverge() {
        var rng = DiffTestRNG(seed: 0x5EED_0F_D1FF)
        let pool = (0..<80).map { Self.id($0) }
        var failures = 0
        for trial in 0..<500 {
            let old = Self.randomTree(pool: pool, rng: &rng)
            let new = trial.isMultiple(of: 2)
                ? Self.randomTree(pool: pool, rng: &rng)
                : Self.mutated(old, pool: pool, rng: &rng)
            if !Self.converges(old, new, label: "trial \(trial)") { failures += 1 }
            if failures >= 3 { break }
        }
        #expect(failures == 0)
    }

    /// The controller applies one diff after another to the same outline, so
    /// each must leave it exactly as a fresh load of its tree would.
    @Test func chainedUpdatesCompose() {
        var rng = DiffTestRNG(seed: 0xC4A1_ED)
        let pool = (0..<80).map { Self.id($0) }
        var tree = Self.randomTree(pool: pool, rng: &rng)
        var outline = OutlineSimulator(tree)
        for step in 0..<300 {
            let next = step.isMultiple(of: 5)
                ? Self.randomTree(pool: pool, rng: &rng)
                : Self.mutated(tree, pool: pool, rng: &rng)
            let update = SidebarTreeDiff.update(from: tree, to: next)
            outline = outline.applying(update.steps, dataSource: next)
            let fresh = OutlineSimulator(next)
            guard outline.violations.isEmpty, outline.visibleRows == fresh.visibleRows,
                  outline.expandedItems == fresh.expandedItems else {
                Issue.record("Chained step \(step) diverged: \(outline.violations)\nold: \(tree.roots)\nnew: \(next.roots)")
                return
            }
            tree = next
        }
    }

    // MARK: Convergence

    /// Diffs `old` into `new`, replays the steps on an outline showing `old`,
    /// and expects the result to match an outline loaded fresh with `new`.
    @discardableResult
    static func converge(
        _ old: SidebarTree, _ new: SidebarTree, sourceLocation: SourceLocation = #_sourceLocation
    ) -> (update: OutlineUpdate, applied: OutlineSimulator) {
        let update = SidebarTreeDiff.update(from: old, to: new)
        let applied = OutlineSimulator(old).applying(update.steps, dataSource: new)
        let fresh = OutlineSimulator(new)
        #expect(applied.violations.isEmpty, "\(applied.violations)", sourceLocation: sourceLocation)
        #expect(applied.visibleRows == fresh.visibleRows, "steps: \(update.steps)", sourceLocation: sourceLocation)
        #expect(applied.expandedItems == fresh.expandedItems, sourceLocation: sourceLocation)
        #expect(fresh.visibleRows.count == new.visibleRowCount, sourceLocation: sourceLocation)
        return (update, applied)
    }

    /// The random-trial form: records one issue naming the trial and the
    /// trees, rather than one per failing expectation.
    static func converges(_ old: SidebarTree, _ new: SidebarTree, label: String) -> Bool {
        let update = SidebarTreeDiff.update(from: old, to: new)
        let applied = OutlineSimulator(old).applying(update.steps, dataSource: new)
        let fresh = OutlineSimulator(new)
        let reconfigureVisible = update.reconfigure.allSatisfy { id in fresh.visibleRows.contains { $0.id == id } }
        guard applied.violations.isEmpty, applied.visibleRows == fresh.visibleRows,
              applied.expandedItems == fresh.expandedItems, fresh.visibleRows.count == new.visibleRowCount,
              reconfigureVisible else {
            Issue.record("""
                \(label) diverged
                violations: \(applied.violations)
                steps: \(update.steps)
                old: \(old.roots)
                new: \(new.roots)
                """)
            return false
        }
        return true
    }

    // MARK: Trees

    static func uuid(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012ld", number))!
    }

    static func id(_ number: Int) -> SidebarNodeID { .worktree(uuid(number)) }

    static func row(_ name: String, height: RowHeightClass = .single) -> SidebarNodeKind {
        .worktree(WorktreeRowModel(
            name: name, leading: nil, isNameBold: false, subtitles: [], suffix: nil,
            showsNoStatusMark: false, showsDevServerDot: false, crossRepoLabel: nil, homeRepoID: nil, isPinned: false,
            depth: 0, isDimmed: false, isInHiddenSection: false, isMain: false, heightClass: height))
    }

    static func node(_ number: Int, _ children: [SidebarNode] = [], expanded: Bool = true,
                     name: String? = nil, height: RowHeightClass = .single) -> SidebarNode {
        SidebarNode(id: id(number), kind: row(name ?? "row \(number)", height: height),
                    children: children, isExpanded: expanded)
    }

    static func tree(_ roots: [SidebarNode]) -> SidebarTree {
        SidebarTree(roots: roots)
    }

    /// Whether `step` is a structural call addressed to `parent`'s children.
    static func isUnder(_ parent: SidebarNodeID, _ step: OutlineStep) -> Bool {
        switch step {
        case .remove(let target, _), .insert(let target, _, _): target == parent
        case .move(let from, _, let to, _): from == parent || to == parent
        default: false
        }
    }

    // MARK: Random trees

    /// Up to 60 nodes drawn from `pool`, at most four levels deep, with random
    /// expansion and content.
    static func randomTree(pool: [SidebarNodeID], rng: inout DiffTestRNG) -> SidebarTree {
        let count = Int(rng.next() % 61)
        var ids = pool.shuffled(using: &rng).prefix(count)
        var roots: [SidebarNode] = []
        while let id = ids.popFirst() {
            roots.append(randomNode(id, ids: &ids, depth: 0, rng: &rng))
        }
        return SidebarTree(roots: roots)
    }

    static func randomNode(_ id: SidebarNodeID, ids: inout ArraySlice<SidebarNodeID>, depth: Int,
                           rng: inout DiffTestRNG) -> SidebarNode {
        var children: [SidebarNode] = []
        if depth < 3 {
            for _ in 0..<Int(rng.next() % 4) {
                guard let child = ids.popFirst() else { break }
                children.append(randomNode(child, ids: &ids, depth: depth + 1, rng: &rng))
            }
        }
        return SidebarNode(id: id, kind: randomKind(rng: &rng), children: children,
                           isExpanded: rng.next() % 3 != 0)
    }

    static func randomKind(rng: inout DiffTestRNG) -> SidebarNodeKind {
        let name = "row \(rng.next() % 3)"
        let height: RowHeightClass = rng.next() % 4 == 0 ? .withSubtitle : .single
        return row(name, height: height)
    }

    /// A flat stand-in for a node, for mutating a tree.
    struct FlatNode {
        var id: SidebarNodeID
        var parent: SidebarNodeID?
        var kind: SidebarNodeKind
        var isExpanded: Bool
    }

    /// `tree` after a handful of random edits — moves (within and across
    /// parents), removals, insertions, expansion flips and content changes —
    /// so most of the tree survives, as it does between real rebuilds.
    static func mutated(_ tree: SidebarTree, pool: [SidebarNodeID], rng: inout DiffTestRNG) -> SidebarTree {
        var flat = flatten(tree.roots, parent: nil)
        for _ in 0..<(1 + Int(rng.next() % 6)) {
            switch rng.next() % 6 {
            case 0 where !flat.isEmpty:
                // Move a node, with its subtree, under a new parent and to a
                // new place among its siblings.
                let moving = flat[Int(rng.next() % UInt64(flat.count))].id
                let subtree = descendants(of: moving, in: flat).union([moving])
                let height = subtreeHeight(of: moving, in: flat)
                let parents: [SidebarNodeID?] = [nil] + flat.map(\.id).filter {
                    !subtree.contains($0) && depth(of: $0, in: flat) + 1 + height <= 3
                }.map { Optional($0) }
                let destination = parents[Int(rng.next() % UInt64(parents.count))]
                guard let index = flat.firstIndex(where: { $0.id == moving }) else { break }
                var node = flat.remove(at: index)
                node.parent = destination
                flat.insert(node, at: Int(rng.next() % UInt64(flat.count + 1)))
            case 1 where !flat.isEmpty:
                // Remove a node and its subtree.
                let removing = flat[Int(rng.next() % UInt64(flat.count))].id
                let gone = descendants(of: removing, in: flat).union([removing])
                flat.removeAll { gone.contains($0.id) }
            case 2:
                // Insert a node the tree does not have.
                let present = Set(flat.map(\.id))
                guard let id = pool.filter({ !present.contains($0) }).randomElement(using: &rng) else { break }
                let parents: [SidebarNodeID?] = [nil] + flat.map(\.id).filter {
                    depth(of: $0, in: flat) < 3
                }.map { Optional($0) }
                let parent = parents[Int(rng.next() % UInt64(parents.count))]
                let node = FlatNode(id: id, parent: parent, kind: randomKind(rng: &rng), isExpanded: rng.next() % 3 != 0)
                flat.insert(node, at: Int(rng.next() % UInt64(flat.count + 1)))
            case 3 where !flat.isEmpty:
                let index = Int(rng.next() % UInt64(flat.count))
                flat[index].isExpanded.toggle()
            case 4 where !flat.isEmpty:
                let index = Int(rng.next() % UInt64(flat.count))
                flat[index].kind = randomKind(rng: &rng)
            default:
                // Shuffle one node among its siblings.
                guard !flat.isEmpty else { break }
                let index = Int(rng.next() % UInt64(flat.count))
                let node = flat.remove(at: index)
                flat.insert(node, at: Int(rng.next() % UInt64(flat.count + 1)))
            }
        }
        return SidebarTree(roots: build(flat, parent: nil))
    }

    static func flatten(_ nodes: [SidebarNode], parent: SidebarNodeID?) -> [FlatNode] {
        nodes.flatMap { node in
            [FlatNode(id: node.id, parent: parent, kind: node.kind, isExpanded: node.isExpanded)]
                + flatten(node.children, parent: node.id)
        }
    }

    /// Children are the nodes naming a parent, in list order.
    static func build(_ flat: [FlatNode], parent: SidebarNodeID?) -> [SidebarNode] {
        flat.filter { $0.parent == parent }.map { node in
            SidebarNode(id: node.id, kind: node.kind, children: build(flat, parent: node.id),
                        isExpanded: node.isExpanded)
        }
    }

    static func descendants(of id: SidebarNodeID, in flat: [FlatNode]) -> Set<SidebarNodeID> {
        var result: Set<SidebarNodeID> = []
        var pending = [id]
        while let current = pending.popLast() {
            for node in flat where node.parent == current && result.insert(node.id).inserted {
                pending.append(node.id)
            }
        }
        return result
    }

    static func depth(of id: SidebarNodeID, in flat: [FlatNode]) -> Int {
        var depth = 0
        var current = flat.first { $0.id == id }?.parent
        while let parent = current {
            depth += 1
            current = flat.first { $0.id == parent }?.parent
        }
        return depth
    }

    static func subtreeHeight(of id: SidebarNodeID, in flat: [FlatNode]) -> Int {
        let children = flat.filter { $0.parent == id }
        return children.map { 1 + subtreeHeight(of: $0.id, in: flat) }.max() ?? 0
    }
}

/// SplitMix64: a small seeded generator, so a failing trial replays exactly.
struct DiffTestRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
