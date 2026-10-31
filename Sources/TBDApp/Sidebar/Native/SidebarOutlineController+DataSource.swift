import AppKit
import os
import TBDShared

private let outlineLogger = Logger(subsystem: "com.tbd.app", category: "native-sidebar")

/// The outline's data source and delegate, and the cells and row views
/// they hand out.
extension SidebarOutlineController {
    /// Returned for a child index the tree does not have, which only a wrong
    /// diff can ask for; the row-count check reloads right after.
    static let orphan = SidebarItem(
        node: SidebarNode(id: .scratchPrompt, kind: .scratchPrompt, children: [], isExpanded: false))

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        tree.children(of: (item as? SidebarItem)?.id).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let children = tree.children(of: (item as? SidebarItem)?.id)
        guard children.indices.contains(index) else {
            let count = children.count
            outlineLogger.fault("Native sidebar asked for child \(index, privacy: .public) of \(count, privacy: .public)")
            return Self.orphan
        }
        return items.item(for: children[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? SidebarItem, item !== Self.orphan else { return false }
        return !tree.children(of: item.id).isEmpty
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarItem, item !== Self.orphan, let node = tree.node(item.id) else { return nil }
        let cell = dequeueCell(for: node.kind)
        configure(cell, kind: node.kind, id: node.id)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = (outlineView.makeView(withIdentifier: SidebarRowView.reuseIdentifier, owner: self)
            as? SidebarRowView) ?? SidebarRowView(frame: .zero)
        if let item = item as? SidebarItem, let node = tree.node(item.id) {
            configure(rowView, node: node)
        }
        return rowView
    }

    /// Every row view AppKit adds — fresh, reused, or moved to a new row —
    /// takes its tint and guide lines from the current tree, so no view shows
    /// a configuration from the row it held before.
    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard let sidebarRow = rowView as? SidebarRowView,
              let item = outlineView.item(atRow: row) as? SidebarItem,
              let node = tree.node(item.id) else { return }
        configure(sidebarRow, node: node)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let item = item as? SidebarItem, let node = tree.node(item.id) else { return WorktreeRowView.rowHeight }
        return rowHeight(for: node.kind)
    }

    /// The model alone expands and collapses: the outline's own gestures would
    /// leave it out of step with the tree the next diff starts from.
    ///
    /// Nothing expands during a drag session, so a collapsed section never
    /// springs open under the pointer. The veto refuses the controller's own
    /// `expandItem` too, so `draggingSession(_:endedAt:)` lifts it before the
    /// held structure replays.
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        isApplyingStructure && !isDragSessionActive
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        isApplyingStructure
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        false
    }

    // MARK: Cells

    private func dequeueCell(for kind: SidebarNodeKind) -> NSTableCellView {
        switch kind {
        case .worktree:
            return dequeue(WorktreeRowCell.reuseIdentifier) { WorktreeRowCell() }
        case .remoteSession:
            return dequeue(RemoteSessionRowCell.reuseIdentifier) { RemoteSessionRowCell() }
        case .scratchHeader, .repoHeader:
            return dequeue(SectionHeaderCell.reuseIdentifier) { SectionHeaderCell() }
        case .providerHeader:
            return dequeue(ProviderHeaderCell.reuseIdentifier) { ProviderHeaderCell() }
        case .groupHeader:
            return dequeue(GroupHeaderCell.reuseIdentifier) { GroupHeaderCell() }
        case .scratchPrompt:
            return dequeue(ScratchPromptCell.reuseIdentifier) { ScratchPromptCell() }
        }
    }

    private func dequeue<Cell: NSTableCellView>(
        _ identifier: NSUserInterfaceItemIdentifier, make: () -> Cell
    ) -> Cell {
        (outline.makeView(withIdentifier: identifier, owner: self) as? Cell) ?? make()
    }

    /// Hands `cell` its model, the insets the chevron placement sets, its
    /// controls' target, and the current hover. Each row ID names one kind
    /// for good, so the cell is always the kind's own.
    func configure(_ cell: NSView, kind: SidebarNodeKind, id: SidebarNodeID) {
        let rowInset = SidebarNativeMetrics.rowContentInset(chevronBeforeTitle: chevronBeforeTitle)
        switch kind {
        case .worktree(let model):
            guard let cell = cell as? WorktreeRowCell else { return }
            cell.leadingInset = rowInset
            wireControls(of: cell, id: id)
            cell.configure(model)
        case .remoteSession(let model):
            guard let cell = cell as? RemoteSessionRowCell else { return }
            cell.leadingInset = rowInset
            cell.toolTips.provider = { [weak self] target in self?.helpText(target, for: id) }
            cell.configure(model)
        case .scratchHeader(let model), .repoHeader(let model):
            guard let cell = cell as? SectionHeaderCell else { return }
            if case .scratchHeader = kind { cell.style = .scratch } else { cell.style = .repo }
            cell.chevronBeforeTitle = chevronBeforeTitle
            cell.leadingInset = SidebarNativeMetrics.headerContentInset
            cell.chevronButton.target = self
            cell.chevronButton.action = #selector(chevronClicked(_:))
            cell.locateButton.target = self
            cell.locateButton.action = #selector(locateClicked(_:))
            cell.plusButton.target = self
            cell.plusButton.action = #selector(sectionPlusClicked(_:))
            cell.configure(model)
        case .providerHeader(let model):
            guard let cell = cell as? ProviderHeaderCell else { return }
            cell.leadingInset = SidebarNativeMetrics.headerContentInset
                + SidebarHeaderMetrics.titleLeadingInset(chevronBeforeProjectName: chevronBeforeTitle)
            cell.plusButton.target = self
            cell.plusButton.action = #selector(providerPlusClicked(_:))
            cell.authButton.target = self
            cell.authButton.action = #selector(authClicked(_:))
            cell.toolTips.provider = { [weak self] target in self?.helpText(target, for: id) }
            cell.configure(model)
        case .groupHeader(let model):
            guard let cell = cell as? GroupHeaderCell else { return }
            cell.leadingInset = rowInset
            cell.configure(model)
        case .scratchPrompt:
            guard let cell = cell as? ScratchPromptCell else { return }
            cell.leadingInset = rowInset + 2
            cell.configure()
        }
        applyHover(to: cell, id: id)
    }

    /// The row view's tint origin, guide lines and provider highlight.
    func configure(_ rowView: SidebarRowView, node: SidebarNode) {
        var configuration = SidebarRowView.Configuration()
        configuration.contentOrigin = SidebarNativeMetrics.rowContentInset(chevronBeforeTitle: chevronBeforeTitle)
        switch node.kind {
        case .worktree(let model):
            let ancestry = worktreeAncestorCount(of: node.id)
            configuration.guideCount = ancestry
            configuration.tintLevel = max(model.depth - ancestry, 0)
            // The pin shows on hover, and always once pinned.
            configuration.showsPinGap = (model.isPinned || hoverState.row == node.id) && !model.isMain
        case .remoteSession(let model):
            configuration.tintLevel = model.depth
        case .providerHeader(let model):
            configuration.highlightsSelectedProvider = model.isSelected
        case .scratchHeader, .repoHeader, .groupHeader, .scratchPrompt:
            break
        }
        configuration.isNestTarget = nestTargetID == node.id
        rowView.configuration = configuration
        configuredRowViews[ObjectIdentifier(rowView)] = node.id
        // `RepoSectionView` dims its rows while the section's chevron is
        // hovered: the gesture is about to hide them.
        rowView.alphaValue = isDimmedByChevron(node) ? 0.7 : 1
    }

    /// How many worktree rows `id` sits under: `WorktreeRowView`'s
    /// `indentLevel`. Group headers between them add padding, not lines.
    private func worktreeAncestorCount(of id: SidebarNodeID) -> Int {
        var count = 0
        var ancestor = tree.parent(of: id)
        while let current = ancestor {
            if case .worktree = current { count += 1 }
            ancestor = tree.parent(of: current)
        }
        return count
    }
}
