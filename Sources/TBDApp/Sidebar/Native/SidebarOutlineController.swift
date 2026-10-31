import AppKit
import Observation
import os
import TBDShared

private let outlineLogger = Logger(subsystem: "com.tbd.app", category: "native-sidebar")

/// Drives the native sidebar's `NSOutlineView` from `AppState`.
///
/// The update loop (spec "Update loop"):
/// 1. The builder runs inside `withObservationTracking`. Its `onChange` fires
///    once, on whichever thread made the change, and disarms; the controller
///    hops to the main thread, sets one rebuild-scheduled flag and rebuilds on
///    the next main-loop turn, re-arming the tracking as it does. A burst of
///    writes costs one pass. `UserDefaults` changes that alter
///    `SidebarBuildOptions` schedule the same rebuild.
/// 2. The first load is a `reloadData`. After it, the new tree is diffed
///    against the shown one and the `OutlineUpdate` is applied in one
///    `beginUpdates`/`endUpdates` block; changed rows are then reconfigured in
///    place and rows whose height class changed get `noteHeightOfRows`.
/// 3. If the outline's row count then disagrees with the tree, the diff was
///    wrong: the controller logs a fault and falls back to `reloadData`.
/// 4. The first visible row's ID and offset are recorded before an apply and
///    restored after it.
/// 5. While a drag or a rename holds the structure, only content applies; the
///    held structure lands when the last hold ends.
///
/// The outline is the only writer of its own structure and expansion: the
/// delegate refuses every expand and collapse the controller did not ask for,
/// so the outline never drifts from the tree the next diff starts from.
@MainActor
final class SidebarOutlineController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// Why structural changes are being held.
    enum HoldReason: Hashable {
        case drag
        case rename
    }

    let appState: AppState
    let defaults: UserDefaults
    let outline = SidebarOutlineView(frame: .zero)
    let scrollView = NSScrollView(frame: .zero)

    /// The tree the outline shows. While structure is held, the held structure
    /// carrying the latest row models.
    private(set) var tree = SidebarTree()

    var isHoldingStructure: Bool { !holds.isEmpty }

    // MARK: Test seams

    /// Builds run so far: what a coalescing test counts.
    private(set) var buildCount = 0
    /// Applies that fell back to `reloadData` because the row count disagreed
    /// with the tree.
    private(set) var fallbackReloadCount = 0
    /// The animation duration in force when the last height change was noted.
    private(set) var lastHeightNoteDuration: TimeInterval?
    /// Stands in for `SidebarTreeDiff.update` so a test can apply a wrong
    /// update and watch the fallback catch it.
    var diffForTesting: ((SidebarTree, SidebarTree) -> OutlineUpdate)?

    // MARK: State

    private var items = SidebarItemCache()
    private var holds: Set<HoldReason> = []
    private var hasLoaded = false
    private var rebuildScheduled = false
    /// True while the controller itself expands, collapses or reloads, the
    /// only time the delegate lets the outline change its expansion.
    private var isApplyingStructure = false
    /// The options the shown tree was built with.
    private var options: SidebarBuildOptions
    /// `AppState.chevronBeforeProjectNameKey`: which side of a section title
    /// its chevron sits on, and with it the column every title and row uses.
    /// Layout only, so a change reconfigures the cells instead of rebuilding.
    private var chevronBeforeTitle: Bool

    /// Whether each unpromoted scratch row's directory exists, read on a
    /// background task so no rebuild touches the disk. A path not yet probed
    /// reads as existing, so a row is never dimmed on a guess.
    private var scratchDirectoryExists: [String: Bool] = [:]
    private var probedScratchPaths: Set<String> = []
    private let scratchDirectoryProbe: @Sendable (String) -> Bool

    nonisolated(unsafe) private var defaultsObserver: (any NSObjectProtocol)?

    private static let signposter = OSSignposter(subsystem: "com.tbd.app", category: "native-sidebar")

    /// Returned for a child index the tree does not have, which only a wrong
    /// diff can ask for; the row-count check reloads right after.
    private static let orphan = SidebarItem(
        node: SidebarNode(id: .scratchPrompt, kind: .scratchPrompt, children: [], isExpanded: false))

    /// - Parameter scratchDirectoryProbe: answers whether a scratch directory
    ///   exists. Runs off the main thread; tests hand in a fixed answer.
    init(
        appState: AppState,
        defaults: UserDefaults,
        scratchDirectoryProbe: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.appState = appState
        self.defaults = defaults
        self.scratchDirectoryProbe = scratchDirectoryProbe
        self.options = SidebarBuildOptions(defaults: defaults)
        self.chevronBeforeTitle = SidebarOutlineController.storedChevronBeforeTitle(defaults)
        super.init(nibName: nil, bundle: nil)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            SidebarOutlineController.performOnMain { self.defaultsDidChange() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    // MARK: View

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tbd.nativeSidebar.column"))
        column.resizingMask = .autoresizingMask
        column.isEditable = false
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        // Custom drawing: `drawSelection(in:)` never runs with `.none` or the
        // source-list style.
        outline.style = .plain
        outline.selectionHighlightStyle = .regular
        outline.rowSizeStyle = .custom
        outline.usesAutomaticRowHeights = false
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.indentationPerLevel = SidebarNativeMetrics.indentation
        outline.indentationMarkerFollowsCell = false
        outline.autoresizesOutlineColumn = false
        outline.autosaveExpandedItems = false
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.allowsColumnReordering = false
        outline.allowsColumnResizing = false
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.floatsGroupRows = false
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Never load inside the SwiftUI update pass that mounted the view.
        scheduleRebuild()
    }

    // MARK: Public surface

    /// Runs a scheduled rebuild now, including the first load. Tests drive the
    /// loop through this instead of waiting for the main-loop turn.
    func flushPendingRebuild() {
        defaultsDidChange()
        guard rebuildScheduled || !hasLoaded else { return }
        rebuildNow()
    }

    func item(for id: SidebarNodeID) -> SidebarItem? {
        items.existing(id)
    }

    func beginHold(_ reason: HoldReason) {
        holds.insert(reason)
    }

    /// Ends one hold; when it was the last, the held structure applies now.
    func endHold(_ reason: HoldReason) {
        guard holds.remove(reason) != nil, holds.isEmpty, hasLoaded else { return }
        rebuildNow()
    }

    /// The fixed height of a row of `kind`: each cell maps its model's height
    /// class to a constant, so nothing measures.
    func rowHeight(for kind: SidebarNodeKind) -> CGFloat {
        switch kind {
        case .worktree(let model): WorktreeRowCell.height(for: model)
        case .remoteSession(let model): RemoteSessionRowCell.height(for: model)
        case .scratchHeader(let model), .repoHeader(let model): SectionHeaderCell.height(for: model)
        case .providerHeader(let model): ProviderHeaderCell.height(for: model)
        case .groupHeader(let model): GroupHeaderCell.height(for: model)
        case .scratchPrompt: ScratchPromptCell.rowHeight
        }
    }

    // MARK: The update loop

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.performScheduledRebuild() }
        }
    }

    private func performScheduledRebuild() {
        guard rebuildScheduled else { return }
        rebuildNow()
    }

    private func rebuildNow() {
        loadViewIfNeeded()
        let interval = Self.signposter.beginInterval("rebuild")
        let state = self.appState
        let store = self.defaults
        let exists = scratchDirectoryExists
        var scratchPaths: Set<String> = []
        var options = self.options
        let latest: SidebarTree = withObservationTracking { () -> SidebarTree in
            options = SidebarBuildOptions(defaults: store)
            scratchPaths = SidebarOutlineController.unpromotedScratchPaths(state.scratchWorktrees)
            return SidebarTreeBuilder.build(state, options: options, directoryExists: { exists[$0] ?? true })
        } onChange: { [weak self] in
            guard let self else { return }
            SidebarOutlineController.performOnMain { self.scheduleRebuild() }
        }
        self.options = options
        buildCount += 1
        // Anything scheduled while building is covered by this build; a change
        // after the tracking re-armed schedules afresh.
        rebuildScheduled = false
        Self.signposter.endInterval("rebuild", interval)
        refreshScratchDirectories(scratchPaths)
        apply(latest)
    }

    /// Runs `body` on the main actor: at once when already on the main thread,
    /// otherwise on the next main-loop turn.
    nonisolated private static func performOnMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }

    private func defaultsDidChange() {
        if SidebarBuildOptions(defaults: defaults) != options {
            scheduleRebuild()
        }
        let stored = Self.storedChevronBeforeTitle(defaults)
        if stored != chevronBeforeTitle {
            chevronBeforeTitle = stored
            reconfigure(nil)
        }
    }

    private static func storedChevronBeforeTitle(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: AppState.chevronBeforeProjectNameKey) as? Bool
            ?? AppState.chevronBeforeProjectNameDefault
    }

    // MARK: Apply

    private func apply(_ latest: SidebarTree) {
        let interval = Self.signposter.beginInterval("apply")
        defer { Self.signposter.endInterval("apply", interval) }
        guard hasLoaded else {
            loadFully(latest)
            return
        }
        let target = isHoldingStructure ? Self.content(of: latest, inStructureOf: tree) : latest
        let update = diffForTesting?(tree, target) ?? SidebarTreeDiff.update(from: tree, to: target)
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
        items.retain(only: tree)

        let shownRows = outline.numberOfRows
        let expectedRows = tree.visibleRowCount
        if shownRows != expectedRows {
            fallbackReloadCount += 1
            outlineLogger.fault(
                "Native sidebar diff left \(shownRows, privacy: .public) rows for a tree of \(expectedRows, privacy: .public); reloading")
            reloadAndExpand()
        } else {
            reconfigure(Set(update.reconfigure))
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
    private func reconfigure(_ ids: Set<SidebarNodeID>?) {
        if let ids, ids.isEmpty { return }
        outline.enumerateAvailableRowViews { rowView, row in
            guard let item = self.outline.item(atRow: row) as? SidebarItem,
                  ids?.contains(item.id) ?? true,
                  let node = self.tree.node(item.id) else { return }
            if let rowView = rowView as? SidebarRowView {
                self.configure(rowView, node: node)
            }
            if let cell = rowView.view(atColumn: 0) as? NSView {
                self.configure(cell, kind: node.kind)
            }
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
        lastHeightNoteDuration = NSAnimationContext.current.duration
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

    private func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        let proposed = NSRect(origin: NSPoint(x: clip.bounds.minX, y: y), size: clip.bounds.size)
        let origin = clip.constrainBoundsRect(proposed).origin
        guard abs(origin.y - clip.bounds.minY) > 0.5 else { return }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Scratch directories

    private static func unpromotedScratchPaths(_ scratches: [Worktree]) -> Set<String> {
        Set(scratches.compactMap { worktree -> String? in
            guard worktree.isScratch, worktree.promotedToRepoID == nil else { return nil }
            return LocalWorktree(worktree)?.path
        })
    }

    /// Probes the scratch directories off the main thread whenever the set of
    /// paths changes, and rebuilds when an answer differs from the cache.
    private func refreshScratchDirectories(_ paths: Set<String>) {
        guard paths != probedScratchPaths else { return }
        probedScratchPaths = paths
        guard !paths.isEmpty else {
            scratchDirectoryExists = [:]
            return
        }
        let probe = scratchDirectoryProbe
        Task.detached(priority: .utility) { [weak self] in
            var found: [String: Bool] = [:]
            for path in paths { found[path] = probe(path) }
            await self?.scratchDirectoriesProbed(found, for: paths)
        }
    }

    private func scratchDirectoriesProbed(_ found: [String: Bool], for paths: Set<String>) {
        guard paths == probedScratchPaths else { return }
        let changed = found.contains { path, exists in (scratchDirectoryExists[path] ?? true) != exists }
        scratchDirectoryExists = found
        if changed { scheduleRebuild() }
    }

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
        configure(cell, kind: node.kind)
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

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let item = item as? SidebarItem, let node = tree.node(item.id) else { return WorktreeRowView.rowHeight }
        return rowHeight(for: node.kind)
    }

    /// The model alone expands and collapses: the outline's own gestures would
    /// leave it out of step with the tree the next diff starts from.
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        isApplyingStructure
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

    /// Hands `cell` its model and the insets the chevron placement sets. Each
    /// row ID names one kind for good, so the cell is always the kind's own.
    private func configure(_ cell: NSView, kind: SidebarNodeKind) {
        let rowInset = SidebarNativeMetrics.rowContentInset(chevronBeforeTitle: chevronBeforeTitle)
        switch kind {
        case .worktree(let model):
            guard let cell = cell as? WorktreeRowCell else { return }
            cell.leadingInset = rowInset
            cell.configure(model)
        case .remoteSession(let model):
            guard let cell = cell as? RemoteSessionRowCell else { return }
            cell.leadingInset = rowInset
            cell.configure(model)
        case .scratchHeader(let model), .repoHeader(let model):
            guard let cell = cell as? SectionHeaderCell else { return }
            if case .scratchHeader = kind { cell.style = .scratch } else { cell.style = .repo }
            cell.chevronBeforeTitle = chevronBeforeTitle
            cell.leadingInset = SidebarNativeMetrics.headerContentInset
            cell.configure(model)
        case .providerHeader(let model):
            guard let cell = cell as? ProviderHeaderCell else { return }
            cell.leadingInset = SidebarNativeMetrics.headerContentInset
                + SidebarHeaderMetrics.titleLeadingInset(chevronBeforeProjectName: chevronBeforeTitle)
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
    }

    /// The row view's tint origin, guide lines and provider highlight.
    private func configure(_ rowView: SidebarRowView, node: SidebarNode) {
        var configuration = SidebarRowView.Configuration()
        configuration.contentOrigin = SidebarNativeMetrics.rowContentInset(chevronBeforeTitle: chevronBeforeTitle)
        switch node.kind {
        case .worktree(let model):
            let ancestry = worktreeAncestorCount(of: node.id)
            configuration.guideCount = ancestry
            configuration.tintLevel = max(model.depth - ancestry, 0)
            // A pinned row shows its pin without hover.
            configuration.showsPinGap = model.isPinned && !model.isMain
        case .remoteSession(let model):
            configuration.tintLevel = model.depth
        case .providerHeader(let model):
            configuration.highlightsSelectedProvider = model.isSelected
        case .scratchHeader, .repoHeader, .groupHeader, .scratchPrompt:
            break
        }
        rowView.configuration = configuration
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
