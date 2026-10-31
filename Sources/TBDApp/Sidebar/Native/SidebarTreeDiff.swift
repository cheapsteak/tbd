import Foundation

/// One call the controller makes on `NSOutlineView`, in order, inside one
/// `beginUpdates`/`endUpdates` block. `NSOutlineView` applies each call to the
/// state the earlier calls left, so every index here is computed by replaying
/// the earlier steps, never read off either tree directly. A nil parent is
/// the outline's root.
///
/// How the controller applies each one:
/// - `remove` – `removeItems(at:inParent:withAnimation:)`.
/// - `insert` – `insertItems(at:inParent:withAnimation:)`. The index is the
///   item's index in the new tree, so the data source answers it with `id`.
/// - `move` – `moveItem(at:inParent:to:inParent:)`. A move within one parent
///   always goes to a lower index, so the result is the same whether the
///   destination index is read before or after the removal.
/// - `reloadItem` – `reloadItem(_:reloadChildren: false)`, so the outline
///   asks again whether the item is expandable.
/// - `expand` – `expandItem(_:expandChildren: false)`; the outline loads the
///   item's children from the data source. Descendants that are expanded too
///   get their own `expand` after it.
/// - `collapse` – `collapseItem(_:collapseChildren: true)`, so the outline
///   keeps no expansion state under the item that the next diff cannot see.
///
/// The diff assumes an item the new tree no longer has is gone for good: the
/// controller drops its `SidebarItem` rather than reusing the object, so the
/// outline cannot remember the old item's expansion if the ID comes back.
enum OutlineStep: Equatable {
    case remove(parent: SidebarNodeID?, index: Int)
    case insert(parent: SidebarNodeID?, index: Int, id: SidebarNodeID)
    case move(fromParent: SidebarNodeID?, fromIndex: Int, toParent: SidebarNodeID?, toIndex: Int)
    case reloadItem(SidebarNodeID)
    case expand(SidebarNodeID)
    case collapse(SidebarNodeID)
}

/// Everything one rebuild asks of the outline.
struct OutlineUpdate: Equatable {
    /// Structural and expansion calls, in order.
    var steps: [OutlineStep]
    /// Rows present before and after whose model changed, top to bottom: the
    /// controller reconfigures their cells in place.
    var reconfigure: [SidebarNodeID]
    /// The rows in `reconfigure` whose height class changed: the controller
    /// calls `noteHeightOfRows` for them.
    var heightChanged: [SidebarNodeID]

    var isEmpty: Bool { steps.isEmpty && reconfigure.isEmpty && heightChanged.isEmpty }
}

/// Diffs two whole `SidebarTree`s into the `OutlineStep`s that take an
/// outline showing the first to one showing the second.
///
/// The diff runs over the whole tree, not per parent, so an ID present in
/// both trees under different parents becomes one `move` and keeps its row
/// view, its subtree's expansion and its selection. It works against a
/// mirror of the outline's state — which items are loaded, which are
/// expanded, which the outline believes are expandable — starting from what
/// an outline showing `old` holds, and updates the mirror after every step it
/// emits, so each step's indices are the ones the outline will see.
///
/// The order, and why:
/// 1. **Collapses the model asks for**, outermost first. Whatever sits under
///    a collapsed item leaves the outline with it, so none of it needs its
///    own removal.
/// 2. **Removals** of loaded items absent from `new`, or whose new parent
///    will not be expanded in the outline (they come back when that parent
///    expands). An item that still holds a row moving elsewhere waits until
///    that row has moved out, so the row keeps its view.
/// 3. **Moves** of every loaded item into its new parent, in its new order.
/// 4. **Removals** of the items that waited in step 2.
/// 5. **Insertions** of items the outline has not loaded, at their final
///    index. A call under a parent that is not expanded is never emitted,
///    since the outline ignores it: that parent's children arrive when it
///    expands.
/// 6. **Expansion**, top down: an item the new tree shows expanded gets
///    `expand`, preceded by `reloadItem` when the outline still believes it
///    has no children (a leaf gaining its first child); an expanded item left
///    with nothing to show gets `collapse`. A parent inserted in this update
///    is expanded here rather than receiving child inserts.
///
/// After the steps, the outline holds exactly what an outline freshly loaded
/// with `new` holds, so the next diff can start from `new` alone.
enum SidebarTreeDiff {
    static func update(from old: SidebarTree, to new: SidebarTree) -> OutlineUpdate {
        var mirror = OutlineMirror(showing: old)
        var steps: [OutlineStep] = []

        collapseWhatTheModelCollapses(&mirror, new: new, steps: &steps)

        var placeable: [SidebarNodeID: Bool] = [:]
        let deferred = removeWhatCannotStay(&mirror, new: new, placeable: &placeable, steps: &steps)
        let targets = placeableParents(in: new, mirror: mirror, placeable: &placeable)
        moveIntoPlace(&mirror, new: new, targets: targets, steps: &steps)
        for id in deferred where mirror.isLoaded(id) {
            remove(id, from: &mirror, steps: &steps)
        }
        insertWhatIsMissing(&mirror, new: new, targets: targets, steps: &steps)
        settleExpansion(&mirror, new: new, steps: &steps)

        var reconfigure: [SidebarNodeID] = []
        var heightChanged: [SidebarNodeID] = []
        for id in mirror.loadedInOrder() {
            guard let before = old.node(id)?.kind, let after = new.node(id)?.kind, before != after else { continue }
            reconfigure.append(id)
            if before.heightClass != after.heightClass { heightChanged.append(id) }
        }
        return OutlineUpdate(steps: steps, reconfigure: reconfigure, heightChanged: heightChanged)
    }

    // MARK: Phases

    private static func collapseWhatTheModelCollapses(
        _ mirror: inout OutlineMirror, new: SidebarTree, steps: inout [OutlineStep]
    ) {
        for id in mirror.loadedInOrder() where mirror.isExpanded(id) {
            guard let node = new.node(id), !node.isExpanded else { continue }
            steps.append(.collapse(id))
            mirror.collapse(id)
        }
    }

    /// Removes every loaded item that cannot stay where the outline can show
    /// it, and returns the ones that must wait for a row inside them to move
    /// out first.
    private static func removeWhatCannotStay(
        _ mirror: inout OutlineMirror, new: SidebarTree,
        placeable: inout [SidebarNodeID: Bool], steps: inout [OutlineStep]
    ) -> [SidebarNodeID] {
        let loaded = mirror.loadedInOrder()
        var stays: Set<SidebarNodeID> = []
        for id in loaded where new.contains(id) {
            if isPlaceable(new.parent(of: id), mirror: mirror, new: new, memo: &placeable) {
                stays.insert(id)
            }
        }
        // Every item with a staying row somewhere beneath it in the outline.
        var holdsStayer: Set<SidebarNodeID> = []
        for id in stays {
            var ancestor = mirror.parent(of: id)
            while let current = ancestor, holdsStayer.insert(current).inserted {
                ancestor = mirror.parent(of: current)
            }
        }
        var deferred: [SidebarNodeID] = []
        for id in loaded where mirror.isLoaded(id) && !stays.contains(id) {
            if holdsStayer.contains(id) {
                deferred.append(id)
            } else {
                remove(id, from: &mirror, steps: &steps)
            }
        }
        return deferred
    }

    /// The parents whose children the outline shows and keeps showing, in the
    /// new tree's order, the root first.
    private static func placeableParents(
        in new: SidebarTree, mirror: OutlineMirror, placeable: inout [SidebarNodeID: Bool]
    ) -> [SidebarNodeID?] {
        var result: [SidebarNodeID?] = [nil]
        var stack: [SidebarNode] = new.roots.reversed()
        while let node = stack.popLast() {
            guard isPlaceable(node.id, mirror: mirror, new: new, memo: &placeable) else { continue }
            result.append(node.id)
            stack.append(contentsOf: node.children.reversed())
        }
        return result
    }

    private static func moveIntoPlace(
        _ mirror: inout OutlineMirror, new: SidebarTree, targets: [SidebarNodeID?], steps: inout [OutlineStep]
    ) {
        for parent in targets {
            let present = new.children(of: parent).map(\.id).filter { mirror.isLoaded($0) }
            for (index, id) in present.enumerated() {
                let current = mirror.children(of: parent)
                if index < current.count, current[index] == id { continue }
                guard let from = mirror.location(of: id) else { continue }
                steps.append(.move(fromParent: from.parent, fromIndex: from.index, toParent: parent, toIndex: index))
                mirror.move(from: from.parent, at: from.index, to: parent, at: index)
            }
        }
    }

    private static func insertWhatIsMissing(
        _ mirror: inout OutlineMirror, new: SidebarTree, targets: [SidebarNodeID?], steps: inout [OutlineStep]
    ) {
        for parent in targets {
            for (index, node) in new.children(of: parent).enumerated() where !mirror.isLoaded(node.id) {
                steps.append(.insert(parent: parent, index: index, id: node.id))
                mirror.insert(node.id, at: index, in: parent, expandable: !node.children.isEmpty)
            }
        }
    }

    private static func settleExpansion(_ mirror: inout OutlineMirror, new: SidebarTree, steps: inout [OutlineStep]) {
        var stack: [SidebarNodeID] = mirror.children(of: nil).reversed()
        while let id = stack.popLast() {
            guard let node = new.node(id) else { continue }
            if !node.children.isEmpty, !mirror.isExpandable(id) {
                steps.append(.reloadItem(id))
                mirror.markExpandable(id)
            }
            if node.showsChildren, !mirror.isExpanded(id) {
                steps.append(.expand(id))
                mirror.expand(id, loading: node.children)
            } else if !node.showsChildren, mirror.isExpanded(id) {
                steps.append(.collapse(id))
                mirror.collapse(id)
            }
            if mirror.isExpanded(id) {
                stack.append(contentsOf: mirror.children(of: id).reversed())
            }
        }
    }

    // MARK: Helpers

    /// Whether the outline shows `parent`'s children now and keeps showing
    /// them: the root, or an item that is loaded and expanded, is in the new
    /// tree, and sits under a placeable parent there. An item loaded under a
    /// placeable parent stays loaded through every step that follows, so the
    /// answer does not change while the diff runs.
    private static func isPlaceable(
        _ parent: SidebarNodeID?, mirror: OutlineMirror, new: SidebarTree, memo: inout [SidebarNodeID: Bool]
    ) -> Bool {
        guard let parent else { return true }
        if let known = memo[parent] { return known }
        var result = false
        if mirror.isExpanded(parent), new.contains(parent) {
            result = isPlaceable(new.parent(of: parent), mirror: mirror, new: new, memo: &memo)
        }
        memo[parent] = result
        return result
    }

    private static func remove(_ id: SidebarNodeID, from mirror: inout OutlineMirror, steps: inout [OutlineStep]) {
        guard let location = mirror.location(of: id) else { return }
        steps.append(.remove(parent: location.parent, index: location.index))
        mirror.remove(at: location.index, in: location.parent)
    }
}

/// What an `NSOutlineView` holds: the child list of the root and of every
/// expanded item, the parent of every loaded item, and whether the outline
/// believes each loaded item is expandable — which it learns when it loads
/// the item and relearns only on `reloadItem`.
private struct OutlineMirror {
    private var lists: [SidebarNodeID?: [SidebarNodeID]] = [nil: []]
    private var parents: [SidebarNodeID: SidebarNodeID?] = [:]
    private var expanded: Set<SidebarNodeID> = []
    private var expandable: [SidebarNodeID: Bool] = [:]

    /// An outline that loaded `tree` and expanded every item it shows
    /// expanded.
    init(showing tree: SidebarTree) {
        load(tree.roots, into: nil)
    }

    private mutating func load(_ nodes: [SidebarNode], into parent: SidebarNodeID?) {
        lists[parent] = nodes.map(\.id)
        for node in nodes {
            parents.updateValue(parent, forKey: node.id)
            expandable[node.id] = !node.children.isEmpty
            if node.showsChildren {
                expanded.insert(node.id)
                load(node.children, into: node.id)
            }
        }
    }

    func isLoaded(_ id: SidebarNodeID) -> Bool { parents.index(forKey: id) != nil }
    func isExpanded(_ id: SidebarNodeID) -> Bool { expanded.contains(id) }
    func isExpandable(_ id: SidebarNodeID) -> Bool { expandable[id] ?? false }
    func parent(of id: SidebarNodeID) -> SidebarNodeID? { parents[id] ?? nil }
    func children(of parent: SidebarNodeID?) -> [SidebarNodeID] { lists[parent] ?? [] }

    func location(of id: SidebarNodeID) -> (parent: SidebarNodeID?, index: Int)? {
        guard let parent = parents[id], let index = lists[parent]?.firstIndex(of: id) else { return nil }
        return (parent, index)
    }

    /// Loaded items, top to bottom.
    func loadedInOrder() -> [SidebarNodeID] {
        var result: [SidebarNodeID] = []
        var stack: [SidebarNodeID] = children(of: nil).reversed()
        while let id = stack.popLast() {
            result.append(id)
            if expanded.contains(id) { stack.append(contentsOf: children(of: id).reversed()) }
        }
        return result
    }

    mutating func remove(at index: Int, in parent: SidebarNodeID?) {
        guard let id = lists[parent]?.remove(at: index) else { return }
        unload(id)
    }

    mutating func insert(_ id: SidebarNodeID, at index: Int, in parent: SidebarNodeID?, expandable isExpandable: Bool) {
        lists[parent, default: []].insert(id, at: index)
        parents.updateValue(parent, forKey: id)
        expandable[id] = isExpandable
    }

    mutating func move(from source: SidebarNodeID?, at sourceIndex: Int, to destination: SidebarNodeID?, at index: Int) {
        guard let id = lists[source]?.remove(at: sourceIndex) else { return }
        lists[destination, default: []].insert(id, at: index)
        parents.updateValue(destination, forKey: id)
    }

    mutating func markExpandable(_ id: SidebarNodeID) {
        expandable[id] = true
    }

    /// Expands `id`, loading `children` collapsed, as the outline loads them
    /// from the data source.
    mutating func expand(_ id: SidebarNodeID, loading children: [SidebarNode]) {
        expanded.insert(id)
        lists[id] = children.map(\.id)
        for child in children {
            parents.updateValue(id, forKey: child.id)
            expandable[child.id] = !child.children.isEmpty
        }
    }

    /// Collapses `id` and forgets everything loaded beneath it.
    mutating func collapse(_ id: SidebarNodeID) {
        guard expanded.remove(id) != nil else { return }
        for child in lists.removeValue(forKey: id) ?? [] { unload(child) }
    }

    private mutating func unload(_ id: SidebarNodeID) {
        parents.removeValue(forKey: id)
        expandable.removeValue(forKey: id)
        collapse(id)
    }
}
