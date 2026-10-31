import AppKit
import os
import TBDShared

private let outlineLogger = Logger(subsystem: "com.tbd.app", category: "native-sidebar")

/// Applying a built tree to the outline: the diff's steps, the fallback
/// reload, in-place reconfiguration, height changes and the scroll anchor.
extension SidebarOutlineController {
    // MARK: Apply

    /// Applies `latest`, then mirrors `AppState`'s selection into the outline.
    /// The selection guard covers the whole apply, through `endUpdates`: the
    /// selection changes the outline posts while rows move are not echoed.
    func apply(_ latest: SidebarTree) {
        let interval = Self.signposter.beginInterval("apply")
        defer { Self.signposter.endInterval("apply", interval) }
        isApplyingModelSelection = true
        if hasLoaded {
            applyUpdate(to: latest)
        } else {
            loadFully(latest)
        }
        applyModelSelection()
        scrollPendingTargetToCenter()
        isApplyingModelSelection = false
        reconcileVanishedSelection()
        // Rows may have moved under a still pointer.
        hoverTracker?.recompute()
    }

    /// Applies the diff from the shown tree to `latest` (or, while held, to
    /// `latest`'s content in the shown structure).
    ///
    /// A row nested onto a former leaf, or into a parent the outline has not
    /// expanded, cannot be moved there: `NSOutlineView` has not loaded that
    /// parent's children. The diff removes it and the parent's `reloadItem`
    /// and `expand` bring it back, under the same `SidebarItem` (its ID is in
    /// the new tree, so the cache keeps it). The selection and scroll anchor
    /// restored at the end of every apply put it back where it was, so only
    /// its row view is new.
    ///
    /// Nothing here asks the outline which item sits at an index while the
    /// update runs: `child(_:ofItem:)` answers through the data source, which
    /// already serves the new tree, so it names the wrong item mid-update.
    private func applyUpdate(to latest: SidebarTree) {
        let target = isHoldingStructure ? Self.content(of: latest, inStructureOf: tree) : latest
        let update = diffForTesting?(tree, target) ?? SidebarTreeDiff.update(from: tree, to: target)
        lastAppliedUpdate = update
        configuredRowViews.removeAll()
        let anchor = captureScrollAnchor()

        isApplyingStructure = true
        tree = target
        if !update.steps.isEmpty {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            NSAnimationContext.current.allowsImplicitAnimation = false
            outline.beginUpdates()
            for step in update.steps { perform(step) }
            outline.endUpdates()
            NSAnimationContext.endGrouping()
        }

        let shownRows = outline.numberOfRows
        let expectedRows = tree.visibleRowCount
        if shownRows != expectedRows {
            fallbackReloadCount += 1
            outlineLogger.fault(
                "Native sidebar diff left \(shownRows, privacy: .public) rows for a tree of \(expectedRows, privacy: .public); reloading")
            // Nothing is pruned yet: the outline may still show items the new
            // tree lacks, and the reload has to be able to let go of them.
            // It prunes once it is done.
            reloadAndExpand()
        } else {
            // The outline has let go of every removed item.
            items.retain(only: tree)
            reconfigure(Set(update.reconfigure))
            // A move changes a row's ancestors even when its own model stays
            // the same, and the row view's tint and guide lines follow them.
            if !update.steps.isEmpty { refreshRowViewConfigurations() }
            noteHeights(update.heightChanged)
        }
        isApplyingStructure = false
        restoreScrollAnchor(anchor)
    }

    private func loadFully(_ latest: SidebarTree) {
        tree = latest
        isApplyingStructure = true
        reloadAndExpand()
        isApplyingStructure = false
        hasLoaded = true
    }

    /// `reloadData`, then expand what the tree shows expanded, top down.
    private func reloadAndExpand() {
        outline.collapseItem(nil, collapseChildren: true)
        outline.reloadData()
        expandShown(tree.roots)
        items.retain(only: tree)
    }

    private func expandShown(_ nodes: [SidebarNode]) {
        for node in nodes where node.showsChildren {
            outline.expandItem(items.item(for: node), expandChildren: false)
            expandShown(node.children)
        }
    }

    private func perform(_ step: OutlineStep) {
        switch step {
        case .remove(let parentID, let index):
            guard let parent = resolve(parentID) else { return }
            outline.removeItems(at: IndexSet(integer: index), inParent: parent.item, withAnimation: [])
        case .insert(let parentID, let index, _):
            guard let parent = resolve(parentID) else { return }
            outline.insertItems(at: IndexSet(integer: index), inParent: parent.item, withAnimation: [])
        case .move(let fromParent, let fromIndex, let toParent, let toIndex):
            guard let source = resolve(fromParent), let destination = resolve(toParent) else { return }
            outline.moveItem(at: fromIndex, inParent: source.item, to: toIndex, inParent: destination.item)
        case .reloadItem(let id):
            guard let item = resolve(id)?.item else { return }
            outline.reloadItem(item, reloadChildren: false)
        case .expand(let id):
            guard let item = resolve(id)?.item else { return }
            outline.expandItem(item, expandChildren: false)
        case .collapse(let id):
            guard let item = resolve(id)?.item else { return }
            outline.collapseItem(item, collapseChildren: true)
        }
    }

    /// An outline item a step names; `item` is nil for the root.
    private struct Resolved {
        let item: SidebarItem?
    }

    /// Resolves a step's ID to the outline's item. Nil — and the step is
    /// skipped — only for an ID the controller cannot resolve, which a correct
    /// diff never names; the row-count check after the block catches the rest.
    private func resolve(_ id: SidebarNodeID?) -> Resolved? {
        guard let id else { return Resolved(item: nil) }
        if let item = items.existing(id) { return Resolved(item: item) }
        guard let node = tree.node(id) else {
            let name = String(describing: id)
            outlineLogger.fault("Native sidebar diff named an unknown item \(name, privacy: .public)")
            return nil
        }
        return Resolved(item: items.item(for: node))
    }

    /// `displayed`'s structure carrying `latest`'s row models: what a held
    /// apply shows, so a status or name change still lands mid-drag.
    static func content(of latest: SidebarTree, inStructureOf displayed: SidebarTree) -> SidebarTree {
        SidebarTree(roots: displayed.roots.map { refreshed($0, from: latest) })
    }

    private static func refreshed(_ node: SidebarNode, from latest: SidebarTree) -> SidebarNode {
        var copy = node
        if let kind = latest.node(node.id)?.kind { copy.kind = kind }
        copy.children = node.children.map { refreshed($0, from: latest) }
        return copy
    }

    // MARK: Content

    /// Reconfigures the rows in `ids` — every row for nil — on every row view
    /// the outline has, including rows prepared ahead of scrolling. A reload
    /// would swap in a recycled cell and lose transient state such as hover.
    func reconfigure(_ ids: Set<SidebarNodeID>?) {
        if let ids, ids.isEmpty { return }
        outline.enumerateAvailableRowViews { rowView, row in
            guard let item = self.outline.item(atRow: row) as? SidebarItem,
                  ids?.contains(item.id) ?? true,
                  let node = self.tree.node(item.id) else { return }
            if let rowView = rowView as? SidebarRowView {
                self.configure(rowView, node: node)
            }
            if let cell = rowView.view(atColumn: 0) as? NSView {
                self.configure(cell, kind: node.kind, id: node.id)
            }
        }
    }

    /// Re-derives every row view's tint and guide lines from the current
    /// tree, after `endUpdates`, by the row each view now shows. Cheap — only
    /// the views the outline holds, each an ancestor walk — and a view whose
    /// configuration is unchanged does not redraw.
    private func refreshRowViewConfigurations() {
        outline.enumerateAvailableRowViews { rowView, row in
            guard let sidebarRow = rowView as? SidebarRowView,
                  let item = self.outline.item(atRow: row) as? SidebarItem,
                  let node = self.tree.node(item.id) else { return }
            self.configure(sidebarRow, node: node)
        }
    }

    /// Tells the outline about rows whose height class changed, inside a
    /// zero-duration animation context so the height does not animate.
    private func noteHeights(_ ids: [SidebarNodeID]) {
        var rows = IndexSet()
        for id in ids {
            guard let item = items.existing(id) else { continue }
            let row = outline.row(forItem: item)
            if row >= 0 { rows.insert(row) }
        }
        guard !rows.isEmpty else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        outline.noteHeightOfRows(withIndexesChanged: rows)
        NSAnimationContext.endGrouping()
    }

    // MARK: Scroll anchor

    private struct ScrollAnchor {
        let id: SidebarNodeID
        /// The row's top minus the clip view's top.
        let offset: CGFloat
    }

    /// The first visible row and its offset, or nil at the very top: a sidebar
    /// scrolled to the top stays there, so a row inserted first is seen.
    private func captureScrollAnchor() -> ScrollAnchor? {
        let top = scrollView.contentView.bounds.minY
        guard top > 0, outline.numberOfRows > 0 else { return nil }
        let row = outline.row(at: NSPoint(x: outline.bounds.midX, y: top))
        guard row >= 0, let item = outline.item(atRow: row) as? SidebarItem else { return nil }
        return ScrollAnchor(id: item.id, offset: outline.rect(ofRow: row).minY - top)
    }

    /// Puts the anchor row back at its offset. `NSTableView` moves the clip
    /// view on its own during layout after height changes, so this runs after
    /// every apply.
    private func restoreScrollAnchor(_ anchor: ScrollAnchor?) {
        guard let anchor, let item = items.existing(anchor.id) else { return }
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        outline.tile()
        scroll(toY: outline.rect(ofRow: row).minY - anchor.offset)
    }

    func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        let proposed = NSRect(origin: NSPoint(x: clip.bounds.minX, y: y), size: clip.bounds.size)
        let origin = clip.constrainBoundsRect(proposed).origin
        guard abs(origin.y - clip.bounds.minY) > 0.5 else { return }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }
}
