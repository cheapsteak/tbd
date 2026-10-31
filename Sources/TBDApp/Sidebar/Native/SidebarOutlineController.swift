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
/// Expanded state lives where the SwiftUI sidebar keeps it, and chevron clicks
/// write it there.
///
/// Selection (spec "Selection"): a user's selection goes to
/// `AppState.selectedWorktreeIDs` through `SidebarSelectionBridge`, whose
/// `didSet` routes it; every apply ends by selecting the rows `AppState`
/// names, under a guard that keeps the outline's own notifications from being
/// echoed back. Each rebuild starts with `SidebarView`'s reveals.
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
    /// Stands in for `SidebarTreeDiff.update` so a test can apply a wrong
    /// update and watch the fallback catch it.
    var diffForTesting: ((SidebarTree, SidebarTree) -> OutlineUpdate)?

    // MARK: State

    private var items = SidebarItemCache()
    /// Items the current update removed from the outline. Their IDs leave the
    /// cache at the removal, so an ID that comes back in the same update — a
    /// row nested onto a former leaf, re-created by the parent's reload — gets
    /// a fresh item; the objects stay alive here until the update is over,
    /// since the outline does not retain them.
    private var releasedDuringApply: [SidebarItem] = []
    /// Rows the current update moved. Their row views' guide lines and tint
    /// follow their ancestors, which a move changes even when the row's own
    /// model does not, so they are reconfigured after the update.
    private var movedDuringApply: [SidebarNodeID] = []
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

    /// True for the whole of an apply, and while the controller mirrors
    /// `AppState`'s selection: the outline's selection notifications then are
    /// the controller's own doing and are not written back.
    private var isApplyingModelSelection = false
    /// Writes the outline made to `AppState.selectedWorktreeIDs`.
    private(set) var appStateSelectionWriteCount = 0
    /// Selection notifications the guard kept from being written back: what
    /// a test counts to prove the guard ran.
    private(set) var suppressedSelectionNotificationCount = 0

    /// `SidebarView`'s reveal state, mirrored: the selection reveal's last
    /// value and whether the first one has run, the Ended reveal's last key,
    /// and a pending scroll target taken from `AppState` for this apply.
    private var lastSelectionReveal: SidebarGroupReveal?
    private var hasSeenSelectionReveal = false
    private var hasRevealedInitialSelection = false
    private var lastEndedRevealKey: EndedRevealKey?
    private var hasSeenEndedRevealKey = false
    private var pendingScrollTarget: UUID?

    /// What re-evaluates the Ended reveal: a new selection event, or the
    /// option turning on. `SidebarView.EndedRevealKey`'s twin.
    private struct EndedRevealKey: Equatable {
        let generation: UInt64
        let selection: RemoteSessionSelection?
    }

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
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
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
        // A click on a header runs the header's action; rows select natively.
        outline.target = self
        outline.action = #selector(outlineClicked(_:))

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

    /// The one column spans the sidebar's width, so cells and row views do.
    override func viewDidLayout() {
        super.viewDidLayout()
        outline.sizeLastColumnToFit()
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
            // Reveals write `AppState` before the tracking is installed, so
            // their writes schedule nothing, and the build below sees them.
            self.performReveals(options: SidebarBuildOptions(defaults: store))
            options = SidebarBuildOptions(defaults: store)
            scratchPaths = SidebarOutlineController.unpromotedScratchPaths(state.scratchWorktrees)
            // The selection the apply mirrors into the outline.
            _ = state.selectedWorktreeIDs
            _ = state.selectedRemoteSession
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

    /// Applies `latest`, then mirrors `AppState`'s selection into the outline.
    /// The selection guard covers the whole apply, through `endUpdates`: the
    /// selection changes the outline posts while rows move are not echoed.
    private func apply(_ latest: SidebarTree) {
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
    }

    /// Applies the diff from the shown tree to `latest` (or, while held, to
    /// `latest`'s content in the shown structure).
    ///
    /// A row nested onto a former leaf, or into a parent the outline has not
    /// expanded, cannot be moved there: `NSOutlineView` has not loaded that
    /// parent's children. The diff removes it and the parent's `reloadItem`
    /// and `expand` bring it back. Its ID then gets a fresh item (see
    /// `releasedDuringApply`), and the selection and scroll anchor restored at
    /// the end of every apply put it back where it was, so only its row view
    /// is new.
    private func applyUpdate(to latest: SidebarTree) {
        defer {
            releasedDuringApply.removeAll()
            movedDuringApply.removeAll()
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
            reconfigureRowViews(under: movedDuringApply)
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
            if let removed = outline.child(index, ofItem: parent.item) as? SidebarItem {
                release(removed)
            }
            outline.removeItems(at: IndexSet(integer: index), inParent: parent.item, withAnimation: [])
        case .insert(let parentID, let index, _):
            guard let parent = resolve(parentID) else { return }
            outline.insertItems(at: IndexSet(integer: index), inParent: parent.item, withAnimation: [])
        case .move(let fromParent, let fromIndex, let toParent, let toIndex):
            guard let source = resolve(fromParent), let destination = resolve(toParent) else { return }
            if let moved = outline.child(fromIndex, ofItem: source.item) as? SidebarItem {
                movedDuringApply.append(moved.id)
            }
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

    /// Drops `item` and everything the outline has loaded beneath it from the
    /// cache, keeping the objects alive until the update ends. Whatever comes
    /// back in this update comes back as a fresh item, never one the outline
    /// has just let go of.
    private func release(_ item: SidebarItem) {
        var pending = [item]
        while let next = pending.popLast() {
            releasedDuringApply.append(next)
            items.evict(next)
            guard outline.isItemExpanded(next) else { continue }
            for index in 0..<outline.numberOfChildren(ofItem: next) {
                if let child = outline.child(index, ofItem: next) as? SidebarItem {
                    pending.append(child)
                }
            }
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

    /// Reconfigures the row views of `ids` and of every row beneath them: their
    /// guide lines and tint depend on their ancestors.
    private func reconfigureRowViews(under ids: [SidebarNodeID]) {
        guard !ids.isEmpty else { return }
        var affected: Set<SidebarNodeID> = []
        var pending = ids.compactMap { tree.node($0) }
        while let node = pending.popLast() {
            affected.insert(node.id)
            pending.append(contentsOf: node.children)
        }
        outline.enumerateAvailableRowViews { rowView, row in
            guard let sidebarRow = rowView as? SidebarRowView,
                  let item = self.outline.item(atRow: row) as? SidebarItem, affected.contains(item.id),
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

    private func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        let proposed = NSRect(origin: NSPoint(x: clip.bounds.minX, y: y), size: clip.bounds.size)
        let origin = clip.constrainBoundsRect(proposed).origin
        guard abs(origin.y - clip.bounds.minY) > 0.5 else { return }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Selection

    /// Selects the rows `AppState` names: its selected worktrees and its
    /// selected remote session. A row the outline does not show is skipped.
    private func applyModelSelection() {
        let remote = appState.selectedRemoteSession.map {
            RemoteSessionIdentity.uuid(provider: $0.provider, sessionID: $0.sessionID)
        }
        let wanted = SidebarSelectionBridge.outlineIDs(
            selectedWorktreeIDs: appState.selectedWorktreeIDs, selectedRemoteSession: remote)
        var rows = IndexSet()
        for id in wanted {
            guard let item = items.existing(id) else { continue }
            let row = outline.row(forItem: item)
            if row >= 0 { rows.insert(row) }
        }
        if rows != outline.selectedRowIndexes {
            outline.selectRowIndexes(rows, byExtendingSelection: false)
        }
    }

    /// Tells `AppState`, once, when a selected worktree left the model during
    /// the apply — the daemon dropped it without `AppState` pruning the
    /// selection. A row merely out of view (a collapsed section, a filter)
    /// stays selected, as it does in the `List`.
    private func reconcileVanishedSelection() {
        let selected = appState.selectedWorktreeIDs
        let unshown = selected.filter { !tree.contains(.worktree($0)) }
        guard !unshown.isEmpty else { return }
        let known = Set(appState.allWorktrees.map(\.id))
        let vanished = unshown.filter { !known.contains($0) }
        guard !vanished.isEmpty else { return }
        writeSelection(selected.subtracting(vanished))
    }

    private func writeSelection(_ ids: Set<UUID>) {
        guard ids != appState.selectedWorktreeIDs else { return }
        appStateSelectionWriteCount += 1
        appState.selectedWorktreeIDs = ids
    }

    // MARK: Header actions and chevrons

    /// The outline's click action: a header runs what the SwiftUI header's tap
    /// runs. Row clicks select through the outline and need nothing here.
    @objc func outlineClicked(_ sender: Any?) {
        handleClick(row: outline.clickedRow)
    }

    func handleClick(row: Int) {
        guard row >= 0, let item = outline.item(atRow: row) as? SidebarItem else { return }
        switch item.id {
        case .repoHeader(let repoID):
            appState.selectRepo(id: repoID)
        case .scratchHeader:
            appState.selectScratchSection()
        case .providerHeader(let name):
            appState.selectRemoteProvider(name)
        case .group(let groupID):
            appState.toggleSidebarGroup(groupID)
        case .scratchPrompt:
            appState.createScratch()
        case .worktree, .remoteSession:
            break
        }
    }

    /// A section header's chevron.
    @objc func chevronClicked(_ sender: NSView) {
        let row = outline.row(for: sender)
        guard row >= 0, let item = outline.item(atRow: row) as? SidebarItem else { return }
        toggleExpansion(of: item.id)
    }

    /// Flips a section's or group's expanded state where it lives — the repo
    /// record, the Scratch section's `@AppStorage` key, or
    /// `expandedSidebarGroups` — and lets the next rebuild apply it. The
    /// outline's own expansion notifications are never read for this.
    func toggleExpansion(of id: SidebarNodeID) {
        switch id {
        case .repoHeader(let repoID):
            guard let repo = appState.repos.first(where: { $0.id == repoID }) else { return }
            let state = appState
            let expanded = !repo.expanded
            Task { await state.setRepoExpanded(id: repoID, expanded: expanded) }
        case .scratchHeader:
            let expanded = SidebarBuildOptions(defaults: defaults).scratchExpanded
            defaults.set(!expanded, forKey: AppState.scratchSectionExpandedKey)
        case .group(let groupID):
            appState.toggleSidebarGroup(groupID)
        case .worktree, .remoteSession, .providerHeader, .scratchPrompt:
            break
        }
    }

    /// A missing repo's Locate… link: the SwiftUI header's panel and relocate.
    @objc func locateClicked(_ sender: NSView) {
        let row = outline.row(for: sender)
        guard row >= 0, let item = outline.item(atRow: row) as? SidebarItem,
              case .repoHeader(let repoID) = item.id,
              let repo = appState.repos.first(where: { $0.id == repoID }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the new location of \(repo.displayName)"
        panel.prompt = "Relocate"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let state = appState
        Task { await state.relocateRepo(id: repoID, newPath: url.path) }
    }

    // MARK: Reveal

    /// `SidebarView`'s three `onChange` handlers, run at the top of every
    /// rebuild: the pending scroll's reveal, the selection reveal with its
    /// baseline rule, and the Ended reveal. They call the same `AppState`
    /// methods, so the two paths reveal alike.
    private func performReveals(options: SidebarBuildOptions) {
        let grouped = options.workflowGroups
        if let target = appState.pendingScrollToWorktreeID {
            appState.revealSidebarGroups(
                appState.sidebarGroupReveal(worktreeIDs: [target], selection: nil), grouped: grouped)
            // Taken now and cleared before the tracking is installed; the
            // apply that follows scrolls to it.
            pendingScrollTarget = target
            appState.pendingScrollToWorktreeID = nil
        }

        let reveal: SidebarGroupReveal? = grouped ? appState.sidebarSelectionReveal : nil
        if !hasSeenSelectionReveal || reveal != lastSelectionReveal {
            // The first evaluation sees the value as both old and new, as
            // `onChange(of:initial: true)` hands it over.
            let previous = hasSeenSelectionReveal ? lastSelectionReveal : reveal
            hasSeenSelectionReveal = true
            lastSelectionReveal = reveal
            if let reveal {
                appState.revealSidebarGroups(
                    reveal,
                    previous: SidebarReveal.baseline(
                        previous: previous, reveal: reveal, hasRevealed: hasRevealedInitialSelection),
                    grouped: grouped)
            }
            hasRevealedInitialSelection = true
        }

        // Nil, reading nothing, unless the option is on and groups are off.
        let key: EndedRevealKey? = !grouped && options.collapseEnded
            ? EndedRevealKey(generation: appState.sidebarSelectionGeneration, selection: appState.selectedRemoteSession)
            : nil
        if !hasSeenEndedRevealKey || key != lastEndedRevealKey {
            hasSeenEndedRevealKey = true
            lastEndedRevealKey = key
            if let key {
                appState.expandedSidebarGroups.formUnion(appState.sidebarEndedRevealGroups(selection: key.selection))
            }
        }
    }

    /// Centres the pending scroll target in the apply that expanded its
    /// section. While structure is held the section may not be shown yet, so
    /// the target waits for the apply that ends the hold. A target with no
    /// row by then is dropped, as the `List` drops it.
    private func scrollPendingTargetToCenter() {
        guard let target = pendingScrollTarget, !isHoldingStructure else { return }
        pendingScrollTarget = nil
        guard let item = items.existing(.worktree(target)) else { return }
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        outline.tile()
        scroll(toY: outline.rect(ofRow: row).midY - scrollView.contentView.bounds.height / 2)
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

    /// Headers run an action from a click instead of taking the selection.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let item = item as? SidebarItem, item !== Self.orphan else { return false }
        return SidebarSelectionBridge.isSelectable(item.id)
    }

    /// A user's selection: written to `AppState.selectedWorktreeIDs` as the
    /// `List`'s tags would write it, then mirrored straight back, since the
    /// `didSet` may route it — a remote row's ID never rests in that set.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingModelSelection else {
            suppressedSelectionNotificationCount += 1
            return
        }
        let selected = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? SidebarItem)?.id }
        writeSelection(SidebarSelectionBridge.appStateIDs(for: selected))
        isApplyingModelSelection = true
        applyModelSelection()
        isApplyingModelSelection = false
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
            cell.chevronButton.target = self
            cell.chevronButton.action = #selector(chevronClicked(_:))
            cell.locateButton.target = self
            cell.locateButton.action = #selector(locateClicked(_:))
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
