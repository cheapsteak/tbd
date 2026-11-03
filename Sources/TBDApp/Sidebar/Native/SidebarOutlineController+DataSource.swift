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
        if let item = item as? SidebarItem {
            configure(rowView, id: item.id)
        }
        return rowView
    }

    /// Every row view AppKit adds — fresh, reused, or moved to a new row —
    /// takes its highlight and guide lines from the current tree, so no view
    /// shows a configuration from the row it held before.
    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard let sidebarRow = rowView as? SidebarRowView,
              let item = outlineView.item(atRow: row) as? SidebarItem else { return }
        configure(sidebarRow, id: item.id)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let item = item as? SidebarItem, let node = tree.node(item.id) else { return SidebarNativeMetrics.rowHeight }
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
        case .addRepository:
            return dequeue(AddRepositoryCell.reuseIdentifier) { AddRepositoryCell() }
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
        case .addRepository:
            guard let cell = cell as? AddRepositoryCell else { return }
            cell.leadingInset = SidebarNativeMetrics.headerContentInset
            cell.addButton.target = self
            cell.addButton.action = #selector(addRepositoryClicked(_:))
            cell.menuButton.target = self
            cell.menuButton.action = #selector(addRepositoryMenuClicked(_:))
            cell.configure()
        }
        applyHover(to: cell, id: id)
    }

    /// What a row view's configuration takes from the tree: everything but
    /// the content origin, which follows the chevron placement, and what the
    /// pointer, the selection and a drag set. Worked out on a row's first
    /// configuration after an apply and kept by row ID until the next
    /// (`rowViewBases`), so a hover or a selection that relights the lines
    /// walks no ancestors and copies no nodes.
    struct RowViewBase {
        /// The row's level, guide lines and own line's start, and whether its
        /// model selects it.
        var configuration = SidebarRowView.Configuration()
        /// Each guide's owner, in `configuration.guides`' order: what the
        /// active lines index.
        var owners: [SidebarNodeID] = []
        var showsHoverHighlight = false
        /// The row has a gutter pin, which sits on its parent's line: a
        /// worktree row other than a repo's main checkout.
        var hasPin = false
        /// The pin shows without hover: the row is pinned.
        var isPinned = false

        /// What `node` in `tree` takes. A header draws selected while
        /// `AppState` selects what it stands for — its repo, the Scratch
        /// section, its provider — which a rebuild carries to it as a
        /// changed model. A row's guide lines are its part in each worktree
        /// line above it, and a worktree row whose worktree children show
        /// starts its own (`GuideHierarchy.rowGuides(of:)`).
        @MainActor
        init(_ node: SidebarNode, in tree: SidebarTree) {
            let lines = tree.rowGuides(of: node.id)
            configuration.guides = lines.guides
            configuration.drawsStub = lines.startsGuide
            owners = lines.owners
            showsHoverHighlight = SidebarOutlineController.showsHoverHighlight(node.kind)
            switch node.kind {
            case .worktree(let model):
                configuration.level = model.depth
                hasPin = !model.isMain
                isPinned = model.isPinned
            case .remoteSession(let model):
                configuration.level = model.depth
            case .groupHeader(let model):
                configuration.level = model.depth
            case .scratchHeader(let model), .repoHeader(let model):
                configuration.isSelectedByModel = model.isSelected
            case .providerHeader(let model):
                configuration.isSelectedByModel = model.isSelected
            case .scratchPrompt, .addRepository:
                break
            }
        }
    }

    /// What the row `id` takes from the tree: kept since this tree was
    /// applied, or worked out now and kept. Nil for a row the tree lacks.
    func rowViewBase(_ id: SidebarNodeID) -> RowViewBase? {
        if let base = rowViewBases[id] { return base }
        guard let node = tree.node(id) else { return nil }
        let base = RowViewBase(node, in: tree)
        rowViewBases[id] = base
        return base
    }

    /// The row view of row `id`: what the tree gives it (`RowViewBase`), the
    /// content origin, and the pointer's, the selection's and a drag's part —
    /// the lines whose owner is in `activeGuideAncestors` draw active, the
    /// pin breaks its line while it shows, on hover and always once pinned,
    /// and the hover and nest highlights. A row the tree lacks keeps its
    /// configuration.
    func configure(_ rowView: SidebarRowView, id: SidebarNodeID) {
        guard let base = rowViewBase(id) else { return }
        let isHovered = hoverState.row == id
        var configuration = base.configuration
        configuration.contentOrigin = SidebarNativeMetrics.rowContentInset(chevronBeforeTitle: chevronBeforeTitle)
        configuration.activeGuides = SidebarGuideLine.activeIndices(of: base.owners, active: activeGuideAncestors)
        configuration.isStubActive = configuration.drawsStub && activeGuideAncestors.contains(id)
        configuration.showsPinGap = base.hasPin && (base.isPinned || isHovered)
        configuration.isHovered = isHovered && base.showsHoverHighlight
        configuration.isNestTarget = nestTargetID == id
        rowView.configuration = configuration
        configuredRowViews[ObjectIdentifier(rowView)] = id
    }

    /// Whether a row of `kind` draws the hover highlight: every row whose
    /// click selects something — the row itself, a header's repo, section or
    /// provider, or the scratch space the prompt creates and selects. A group
    /// header's click only opens or closes the group, so it draws none, and
    /// the Add Repository row's buttons draw their own washes instead.
    static func showsHoverHighlight(_ kind: SidebarNodeKind) -> Bool {
        switch kind {
        case .worktree, .remoteSession, .scratchHeader, .repoHeader, .providerHeader, .scratchPrompt:
            true
        case .groupHeader, .addRepository:
            false
        }
    }

    // MARK: Active guide lines

    /// The active ancestors of the hovered row and of each selected worktree
    /// row the outline shows.
    func focusedGuideAncestors() -> Set<SidebarNodeID> {
        var focus = appState.selectedWorktreeIDs.map { SidebarNodeID.worktree($0) }
        if let hovered = hoverState.row { focus.append(hovered) }
        return tree.activeGuideAncestors(of: focus)
    }

    /// Recomputes the active guide lines after the selection or the tree
    /// changed. When they differ, or `refreshingRowViews` asks, every row
    /// view the outline holds takes its configuration afresh; a view whose
    /// configuration comes out the same does not redraw.
    func refreshActiveGuides(refreshingRowViews: Bool = false) {
        let active = focusedGuideAncestors()
        guard refreshingRowViews || active != activeGuideAncestors else { return }
        activeGuideAncestors = active
        refreshRowViewConfigurations()
    }
}
