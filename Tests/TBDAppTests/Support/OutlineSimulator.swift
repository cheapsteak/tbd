import Foundation
@testable import TBDApp

/// A pure model of `NSOutlineView`'s documented update semantics, to replay
/// `OutlineStep`s against without AppKit. Written independently of the
/// diff's own mirror, so the two have to agree rather than share a mistake.
///
/// What it models:
/// - Each call applies to the state the earlier calls left.
/// - The outline holds a child list for the root and for every expanded item,
///   and nothing for the children of an item that is not expanded.
/// - An insert, removal or move under a parent that is not expanded is
///   ignored.
/// - Inserting asks the data source for the child at the given index, so the
///   index must already be the item's final one.
/// - The outline caches whether an item is expandable when it loads the item,
///   and asks again only on `reloadItem`; `expand` of an item it believes has
///   no children is ignored.
/// - `expand` loads the item's children from the data source, collapsed.
/// - `collapse` forgets everything loaded beneath the item.
///
/// A call the real outline would ignore, or that has no defined outcome, is
/// ignored here too and recorded in `violations`: the diff promises never to
/// emit one, so a test fails on any.
struct OutlineSimulator {
    /// One shown row.
    struct Row: Equatable, CustomStringConvertible {
        let id: SidebarNodeID
        let parent: SidebarNodeID?
        let level: Int

        var description: String { "\(String(repeating: "  ", count: level))\(id)" }
    }

    private(set) var violations: [String] = []
    /// The item each applied `remove` took out, and each `insert` put in, in
    /// order — what a test asks to prove a moved row was never removed and
    /// reinserted.
    private(set) var removed: [SidebarNodeID] = []
    private(set) var inserted: [SidebarNodeID] = []
    private var lists: [SidebarNodeID?: [SidebarNodeID]] = [nil: []]
    private var expanded: Set<SidebarNodeID> = []
    private var cachedExpandable: [SidebarNodeID: Bool] = [:]

    /// The outline after `reloadData` with `tree` as its data source, and the
    /// controller expanding every item the tree shows expanded, top down.
    init(_ tree: SidebarTree) {
        lists[nil] = tree.roots.map(\.id)
        for root in tree.roots { cachedExpandable[root.id] = !root.children.isEmpty }
        var pending = tree.roots
        while !pending.isEmpty {
            let node = pending.removeFirst()
            guard node.isExpanded, cachedExpandable[node.id] == true else { continue }
            expanded.insert(node.id)
            lists[node.id] = node.children.map(\.id)
            for child in node.children { cachedExpandable[child.id] = !child.children.isEmpty }
            pending.append(contentsOf: node.children)
        }
    }

    /// Applies `steps` in order, with `dataSource` answering every question
    /// the outline asks while it does — the new tree, as during a real
    /// `beginUpdates`/`endUpdates` block.
    func applying(_ steps: [OutlineStep], dataSource: SidebarTree) -> OutlineSimulator {
        var result = self
        for (position, step) in steps.enumerated() {
            result.apply(step, at: position, dataSource: dataSource)
        }
        return result
    }

    /// The rows the outline shows, top to bottom.
    var visibleRows: [Row] {
        var rows: [Row] = []
        appendRows(under: nil, level: 0, into: &rows)
        return rows
    }

    /// The items the outline shows expanded.
    var expandedItems: Set<SidebarNodeID> { expanded }

    // MARK: Steps

    private mutating func apply(_ step: OutlineStep, at position: Int, dataSource: SidebarTree) {
        switch step {
        case let .remove(parent, index):
            guard isOpen(parent) else { return violate(position, step, "parent is not expanded") }
            guard let list = lists[parent], list.indices.contains(index) else {
                return violate(position, step, "index out of range")
            }
            let id = list[index]
            lists[parent]?.remove(at: index)
            forget(id)
            removed.append(id)

        case let .insert(parent, index, id):
            guard isOpen(parent) else { return violate(position, step, "parent is not expanded") }
            guard let list = lists[parent], index >= 0, index <= list.count else {
                return violate(position, step, "index out of range")
            }
            guard !isShown(id) else { return violate(position, step, "item is already in the outline") }
            let answered = dataSource.children(of: parent)
            guard answered.indices.contains(index), answered[index].id == id else {
                return violate(position, step, "the data source has a different item at that index")
            }
            lists[parent]?.insert(id, at: index)
            cachedExpandable[id] = !answered[index].children.isEmpty
            inserted.append(id)

        case let .move(fromParent, fromIndex, toParent, toIndex):
            guard isOpen(fromParent), isOpen(toParent) else {
                return violate(position, step, "a parent is not expanded")
            }
            guard let source = lists[fromParent], source.indices.contains(fromIndex) else {
                return violate(position, step, "source index out of range")
            }
            if fromParent == toParent, toIndex > fromIndex {
                return violate(position, step, "a move to a later index in the same parent is ambiguous")
            }
            let id = source[fromIndex]
            if let destination = toParent, destination == id || isAncestor(id, of: destination) {
                return violate(position, step, "moves an item into its own subtree")
            }
            lists[fromParent]?.remove(at: fromIndex)
            guard let target = lists[toParent], toIndex >= 0, toIndex <= target.count else {
                lists[fromParent]?.insert(id, at: fromIndex)
                return violate(position, step, "destination index out of range")
            }
            lists[toParent]?.insert(id, at: toIndex)

        case let .reloadItem(id):
            guard isShown(id) else { return violate(position, step, "item is not in the outline") }
            guard !expanded.contains(id) else {
                return violate(position, step, "reloading an expanded item is not modeled")
            }
            cachedExpandable[id] = !(dataSource.node(id)?.children.isEmpty ?? true)

        case let .expand(id):
            guard isShown(id) else { return violate(position, step, "item is not in the outline") }
            guard !expanded.contains(id) else { return violate(position, step, "item is already expanded") }
            guard cachedExpandable[id] == true else {
                return violate(position, step, "the outline believes the item has no children")
            }
            let children = dataSource.node(id)?.children ?? []
            expanded.insert(id)
            lists[id] = children.map(\.id)
            for child in children { cachedExpandable[child.id] = !child.children.isEmpty }

        case let .collapse(id):
            guard expanded.contains(id) else { return violate(position, step, "item is not expanded") }
            collapse(id)
        }
    }

    private mutating func violate(_ position: Int, _ step: OutlineStep, _ reason: String) {
        violations.append("step \(position) \(step): \(reason)")
    }

    // MARK: State

    private func isOpen(_ parent: SidebarNodeID?) -> Bool {
        guard let parent else { return true }
        return expanded.contains(parent)
    }

    /// Whether `id` sits in some loaded child list.
    private func isShown(_ id: SidebarNodeID) -> Bool {
        lists.values.contains { $0.contains(id) }
    }

    private func parentOf(_ id: SidebarNodeID) -> SidebarNodeID?? {
        for (parent, list) in lists where list.contains(id) { return .some(parent) }
        return nil
    }

    private func isAncestor(_ candidate: SidebarNodeID, of id: SidebarNodeID) -> Bool {
        var current = parentOf(id)
        while case .some(.some(let parent)) = current {
            if parent == candidate { return true }
            current = parentOf(parent)
        }
        return false
    }

    private mutating func collapse(_ id: SidebarNodeID) {
        expanded.remove(id)
        for child in lists.removeValue(forKey: id) ?? [] { forget(child) }
    }

    private mutating func forget(_ id: SidebarNodeID) {
        cachedExpandable.removeValue(forKey: id)
        if expanded.contains(id) { collapse(id) }
    }

    private func appendRows(under parent: SidebarNodeID?, level: Int, into rows: inout [Row]) {
        for id in lists[parent] ?? [] {
            rows.append(Row(id: id, parent: parent, level: level))
            if expanded.contains(id) { appendRows(under: id, level: level + 1, into: &rows) }
        }
    }
}
