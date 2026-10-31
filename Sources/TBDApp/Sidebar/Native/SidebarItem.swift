import AppKit

/// One item of the native sidebar's outline.
///
/// `NSOutlineView` identifies items by object identity, so the controller keeps
/// exactly one `SidebarItem` per `SidebarNodeID` for as long as that node is in
/// the tree the outline shows. The same row is the same object across rebuilds,
/// which is what lets a move keep the row's view, its subtree's expansion and
/// its selection. An `NSObject`, so the outline's own `isEqual:` lookups compare
/// identity.
final class SidebarItem: NSObject {
    let id: SidebarNodeID
    /// The node's latest value, refreshed after every apply.
    var node: SidebarNode

    init(node: SidebarNode) {
        self.id = node.id
        self.node = node
    }

    override var description: String { "SidebarItem(\(id))" }
}

/// The ID-keyed store of `SidebarItem`s.
///
/// `NSOutlineView` does not retain its items, so this cache is what keeps them
/// alive. An item is made the first time the outline asks for its node and is
/// dropped once the node leaves the shown tree, never reused: a node that comes
/// back gets a fresh object, so the outline cannot carry over expansion it
/// remembered for the old one (see `OutlineStep`).
struct SidebarItemCache {
    private var items: [SidebarNodeID: SidebarItem] = [:]

    var count: Int { items.count }

    /// The item already made for `id`, or nil.
    func existing(_ id: SidebarNodeID) -> SidebarItem? {
        items[id]
    }

    /// The item for `node`, made on first use.
    mutating func item(for node: SidebarNode) -> SidebarItem {
        if let item = items[node.id] { return item }
        let item = SidebarItem(node: node)
        items[node.id] = item
        return item
    }

    /// Forgets `item`, if it is still the one the cache holds for its ID, so
    /// the next request for that ID makes a fresh item. The caller keeps the
    /// object alive for as long as the outline may still touch it.
    mutating func evict(_ item: SidebarItem) {
        if items[item.id] === item {
            items[item.id] = nil
        }
    }

    /// Keeps only the items of nodes in `tree`, each refreshed to the node's
    /// latest value. Called once the outline has finished an update, so an
    /// item it was still removing is not released under it.
    mutating func retain(only tree: SidebarTree) {
        var kept: [SidebarNodeID: SidebarItem] = [:]
        kept.reserveCapacity(items.count)
        Self.collect(tree.roots, from: items, into: &kept)
        items = kept
    }

    private static func collect(
        _ nodes: [SidebarNode], from old: [SidebarNodeID: SidebarItem], into kept: inout [SidebarNodeID: SidebarItem]
    ) {
        for node in nodes {
            if let item = old[node.id] {
                item.node = node
                kept[node.id] = item
            }
            collect(node.children, from: old, into: &kept)
        }
    }
}
