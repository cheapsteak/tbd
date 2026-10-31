import AppKit
import Observation
import os
import TBDShared

private let dockLogger = Logger(subsystem: "com.tbd.app", category: "native-sidebar")

/// What one pinned dock row draws: the outline's own row models.
enum DockRowKind: Equatable {
    case worktree(WorktreeRowModel)
    case remoteSession(RemoteSessionRowModel)
}

/// One row of the native pinned dock: a pinned root, a descendant shown while
/// its root's subtree holds the selection, or a pinned remote session.
struct DockRow: Equatable {
    /// The ID the row has in the outline, so the two lists mirror one
    /// selection.
    let id: SidebarNodeID
    var kind: DockRowKind
    /// 0 for a pinned root and every remote pin; 1+ for a descendant.
    var depth: Int

    var isWorktree: Bool {
        if case .worktree = kind { return true }
        return false
    }

    /// The rows a reorder moves: only pinned roots carry a pin order.
    var isPinnedRoot: Bool { isWorktree && depth == 0 }

    /// The row as an outline node's kind, for what the dock shares with the
    /// outline: the context menus and the rename editor.
    var nodeKind: SidebarNodeKind {
        switch kind {
        case .worktree(let model): .worktree(model)
        case .remoteSession(let model): .remoteSession(model)
        }
    }
}

/// The native pinned dock: an `NSTableView` over `PinnedDockContent`, below
/// the outline (spec "Scope", "Architecture" and "Drag and drop" › "Dock").
///
/// - **Rows.** `PinnedDockContent.rows` — the pinned roots in pin order, each
///   followed by its subtree while it or a descendant is selected — then
///   `PinnedDockContent.remoteRows`, each drawn by the outline's own cells from
///   `SidebarRowModelFactory`'s models.
/// - **Update loop.** The outline's: the builder runs inside
///   `withObservationTracking`, a change schedules one rebuild on the next
///   main-loop turn, and the apply runs outside SwiftUI's update pass. The
///   rows are flat, so the apply is a `CollectionDifference` over their IDs in
///   one `beginUpdates` block, then an in-place reconfigure of rows whose
///   model changed. A wrong row count falls back to `reloadData`. A drag or a
///   rename holds the rows; content still applies.
/// - **Selection.** The dock and the outline mirror the one selection set:
///   a user's selection goes to `AppState.selectedWorktreeIDs` through
///   `SidebarSelectionBridge`, and every apply ends by selecting the rows
///   `AppState` names, under a guard that keeps the table's own
///   notifications from being written back.
/// - **Reorder.** Only pinned roots drag, under the dock's own pasteboard
///   type, which the outline does not register; the dock registers only that
///   type. A drop calls `AppState.reorderPins(fromOffsets:toOffset:)` with
///   offsets into the roots, as the SwiftUI dock's `.onMove` does.
/// - **Hover.** A `SidebarHoverTracker` of its own shows the hovered row's
///   gutter pin and nested `+`, as the outline's rows show them. The `+` opens
///   the one `SidebarPlusMenu` the whole sidebar shares.
///
/// Every dock row is `PinnedDockMetrics.rowHeight` tall, which the container's
/// height clamp counts on.
@MainActor
final class DockTableController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// Why the rows are being held.
    enum HoldReason: Hashable {
        case drag
        case rename
    }

    /// Where every dock row's content starts: the SwiftUI dock's fixed 12 pt
    /// `listRowInsets`, whichever side the section chevrons sit on.
    static var rowInset: CGFloat {
        SidebarNativeMetrics.rowContentInset(chevronBeforeTitle: false)
    }

    let appState: AppState
    let defaults: UserDefaults
    /// The sheet slot `NativeSidebarView` presents with SwiftUI, shared with
    /// the outline.
    let sheets: NativeSidebarSheetPresenter
    let table = DockTableView(frame: .zero)
    let scrollView = NSScrollView(frame: .zero)

    /// The rows the table shows, top to bottom. While the rows are held, the
    /// held rows carrying the latest models. Written only by the apply.
    private(set) var rows: [DockRow] = []
    /// Runs after an apply changed the number of rows; the container resizes
    /// the dock.
    var onRowCountChange: (() -> Void)?

    /// Answers whether an unpromoted scratch row's directory exists. The
    /// container hands in the outline's cache of answers probed off the main
    /// thread, so no rebuild touches the disk.
    private let directoryExists: (String) -> Bool

    /// The `+` menu, shared with the outline inside the container.
    let plusMenu: SidebarPlusMenu
    /// Whether the dock made `plusMenu` itself, and so refreshes its own rows
    /// when the menu opens or closes. Otherwise the container does.
    private let ownsPlusMenu: Bool
    /// Drives the hover tracker's 80 ms section debounce, which the dock,
    /// having no sections, never starts.
    private let hoverClock: any Clock<Duration>
    /// Made with the view; the table keeps it alive.
    private(set) var hoverTracker: SidebarHoverTracker?
    /// What the pointer was last reported over.
    private(set) var hoverState = SidebarHoverTracker.State()

    // MARK: Test seams

    /// Applies that fell back to `reloadData` because the row count disagreed
    /// with the rows.
    private(set) var fallbackReloadCount = 0
    /// Writes the dock made to `AppState.selectedWorktreeIDs`.
    private(set) var appStateSelectionWriteCount = 0
    /// Selection notifications the guard kept from being written back.
    private(set) var suppressedSelectionNotificationCount = 0
    /// Stands in for `AppState.reorderPins(fromOffsets:toOffset:)`, whose RPC
    /// a test cannot reach.
    var reorderPinsForTesting: ((IndexSet, Int) -> Void)?
    /// Opens a pull request's page; tests hand in a recorder.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// The modifier keys of the event that changed the selection: what tells
    /// a ⌘- or ⇧-click from a plain one. Tests hand in fixed keys.
    var selectionModifiers: @MainActor () -> NSEvent.ModifierFlags = {
        NSApplication.shared.currentEvent?.modifierFlags ?? []
    }

    // MARK: State

    private var holds: Set<HoldReason> = []
    private var hasLoaded = false
    private var rebuildScheduled = false
    /// True for the whole of an apply, and while the dock mirrors `AppState`'s
    /// selection: the table's selection notifications then are the dock's own
    /// doing and are not written back.
    private var isApplyingModelSelection = false
    /// The selection the last apply mirrored; a new one scrolls its first row
    /// into view, as the SwiftUI dock's `onChange` handlers do.
    private var lastSelection: SelectionKey?
    /// The pins a drag carries, read from its pasteboard once per drag:
    /// `validateDrop` runs on every pointer move.
    private var dropPayloadCache: (sequence: Int, ids: [UUID])?
    private var renameEditor: SidebarRenameEditor?
    private weak var renamingCell: NSView?

    private struct SelectionKey: Equatable {
        let worktrees: Set<UUID>
        let remote: RemoteSessionSelection?
    }

    var isHoldingStructure: Bool { !holds.isEmpty }

    /// - Parameters:
    ///   - sheets: the slot the SwiftUI wrapper presents sheets from; a dock
    ///     mounted on its own gets one of its own.
    ///   - directoryExists: answers for unpromoted scratch rows. A dock with
    ///     no answers dims none.
    ///   - plusMenu: the outline's `+` menu; a dock mounted on its own gets
    ///     one of its own.
    ///   - clock: the hover tracker's clock.
    init(
        appState: AppState,
        defaults: UserDefaults,
        sheets: NativeSidebarSheetPresenter? = nil,
        directoryExists: @escaping (String) -> Bool = { _ in true },
        plusMenu: SidebarPlusMenu? = nil,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.appState = appState
        self.defaults = defaults
        self.sheets = sheets ?? NativeSidebarSheetPresenter()
        self.directoryExists = directoryExists
        self.plusMenu = plusMenu ?? SidebarPlusMenu()
        self.ownsPlusMenu = plusMenu == nil
        self.hoverClock = clock
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: View

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tbd.nativeSidebar.dockColumn"))
        column.resizingMask = .autoresizingMask
        column.isEditable = false
        table.addTableColumn(column)
        table.headerView = nil
        // Custom drawing, as in the outline: `SidebarRowView` draws the tint.
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.rowSizeStyle = .custom
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        // A click on a row's PR glyph opens the pull request; rows select
        // natively.
        table.target = self
        table.action = #selector(tableClicked(_:))
        table.contextMenuProvider = { [weak self] row in self?.contextMenu(forRow: row) }

        // The dock's own type only: rows never cross between the dock and the
        // list, whose type the dock does not register.
        table.registerForDraggedTypes([.tbdDockPin])
        // Pins move within the dock and never leave the app.
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        // After the selection highlight style, which can reset it: the table
        // draws the insertion line between roots itself.
        table.draggingDestinationFeedbackStyle = .regular

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        view = scrollView
        installHover()
    }

    /// The hover tracker, made once the table is in its scroll view, so it
    /// recomputes on every scroll. A dock row sits in no section.
    private func installHover() {
        let tracker = SidebarHoverTracker(
            table: table,
            resolve: { [weak self] index in self?.hoverRow(index) },
            onChange: { [weak self] state in self?.hoverChanged(state) },
            clock: hoverClock)
        table.hoverTracker = tracker
        hoverTracker = tracker
        if ownsPlusMenu {
            plusMenu.onOpenChange = { [weak self] _, _ in self?.applyHoverToAvailableRows() }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Never load inside the SwiftUI update pass that mounted the view.
        scheduleRebuild()
    }

    /// The one column spans the dock's width, so cells and row views do.
    override func viewDidLayout() {
        super.viewDidLayout()
        table.sizeLastColumnToFit()
    }

    // MARK: Public surface

    /// Runs a scheduled rebuild now, including the first load. Tests drive the
    /// loop through this instead of waiting for the main-loop turn.
    func flushPendingRebuild() {
        guard rebuildScheduled || !hasLoaded else { return }
        rebuildNow()
    }

    /// Schedules one rebuild on the next main-loop turn; further calls before
    /// it runs are covered by it.
    func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.performScheduledRebuild() }
        }
    }

    func beginHold(_ reason: HoldReason) {
        holds.insert(reason)
        // Nothing is hovered under a drag; the next pointer move recomputes.
        if reason == .drag { hoverTracker?.clear() }
    }

    /// Ends one hold; when it was the last, the held rows update now.
    func endHold(_ reason: HoldReason) {
        guard holds.remove(reason) != nil, holds.isEmpty, hasLoaded else { return }
        rebuildNow()
    }

    // MARK: The update loop

    private func performScheduledRebuild() {
        guard rebuildScheduled else { return }
        rebuildNow()
    }

    private func rebuildNow() {
        loadViewIfNeeded()
        let state = appState
        let directoryExists = self.directoryExists
        let latest = withObservationTracking { () -> [DockRow] in
            // The selection the apply mirrors into the table. The worktree
            // selection is read by the build, which opens subtrees from it.
            _ = state.selectedRemoteSession
            return DockTableController.build(state, directoryExists: directoryExists)
        } onChange: { [weak self] in
            // On the writing thread; the weak reference is read on the main
            // one, so the controller is never released anywhere else.
            DockTableController.performOnMain { self?.scheduleRebuild() }
        }
        // Anything scheduled while building is covered by this build; a change
        // after the tracking re-armed schedules afresh.
        rebuildScheduled = false
        apply(latest)
    }

    /// The dock's rows for `appState`, each model computed the way the outline
    /// computes it. Writes nothing to `AppState`.
    static func build(_ appState: AppState, now: Date = Date(),
                      directoryExists: @escaping (String) -> Bool) -> [DockRow] {
        let models = SidebarRowModelFactory(appState: appState, now: now, directoryExists: directoryExists)
        let pinned = PinnedDockContent.rows(
            allWorktrees: appState.allWorktrees,
            selectedIDs: appState.selectedWorktreeIDs,
            children: appState.children(of:))
        let remote = PinnedDockContent.remoteRows(allRemoteSessions: appState.remoteSessions)
        var rows: [DockRow] = []
        rows.reserveCapacity(pinned.count + remote.count)
        for row in pinned {
            // A dock row sits under no section: nothing is hidden or dimmed
            // for its repo, as `PinnedDockView` renders it.
            let model = models.worktree(
                row.worktree, isMain: row.worktree.status == .main, depth: row.depth,
                sectionRepoID: row.sectionRepoID, isInHiddenSection: false)
            rows.append(DockRow(id: .worktree(row.worktree.id), kind: .worktree(model), depth: row.depth))
        }
        for row in remote {
            let model = models.remoteSession(row.session, depth: 0, isInHiddenSection: false)
            rows.append(DockRow(id: .remoteSession(row.id), kind: .remoteSession(model), depth: 0))
        }
        return rows
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

    // MARK: Apply

    /// Applies `latest`, then mirrors `AppState`'s selection into the table.
    /// The selection guard covers the whole apply, through `endUpdates`.
    func apply(_ latest: [DockRow]) {
        let previousCount = rows.count
        isApplyingModelSelection = true
        if hasLoaded {
            applyUpdate(to: isHoldingStructure ? Self.content(of: latest, inStructureOf: rows) : latest)
        } else {
            rows = latest
            table.reloadData()
            hasLoaded = true
        }
        applyModelSelection()
        isApplyingModelSelection = false
        // The dock takes its new height before a new selection scrolls into
        // it, so the scroll reads the height the rows will have.
        if rows.count != previousCount {
            onRowCountChange?()
        }
        scrollNewSelectionIntoView()
        // Rows may have moved under a still pointer.
        hoverTracker?.recompute()
        plusMenu.closeIfOwnerLeft(table) { owner in rows.contains { $0.id == owner } }
    }

    /// Inserts and removes rows by ID, so a row that stays keeps its row view
    /// and its cell, then reconfigures rows whose model changed in place.
    private func applyUpdate(to target: [DockRow]) {
        let previous = rows
        rows = target
        let oldIDs = previous.map(\.id)
        let newIDs = target.map(\.id)
        if oldIDs != newIDs {
            // Removals index the old rows, insertions the new ones: the order
            // `removeRows` then `insertRows` read them in.
            var removed = IndexSet()
            var inserted = IndexSet()
            for change in newIDs.difference(from: oldIDs) {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            NSAnimationContext.current.allowsImplicitAnimation = false
            table.beginUpdates()
            if !removed.isEmpty { table.removeRows(at: removed, withAnimation: []) }
            if !inserted.isEmpty { table.insertRows(at: inserted, withAnimation: []) }
            table.endUpdates()
            NSAnimationContext.endGrouping()
        }

        let shownRows = table.numberOfRows
        let expectedRows = rows.count
        guard shownRows == expectedRows else {
            fallbackReloadCount += 1
            dockLogger.fault(
                "Native dock update left \(shownRows, privacy: .public) rows for \(expectedRows, privacy: .public); reloading")
            table.reloadData()
            return
        }
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed: Set<SidebarNodeID> = []
        for row in target {
            if let old = before[row.id], old != row { changed.insert(row.id) }
        }
        reconfigure(changed)
    }

    /// `shown`'s rows carrying `latest`'s models: what a held apply shows, so a
    /// status or name change still lands mid-drag or mid-rename.
    static func content(of latest: [DockRow], inStructureOf shown: [DockRow]) -> [DockRow] {
        let fresh = Dictionary(latest.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        return shown.map { row in
            guard let kind = fresh[row.id] else { return row }
            var copy = row
            copy.kind = kind
            return copy
        }
    }

    /// Reconfigures the rows in `ids` on every row view the table has,
    /// including rows prepared ahead of scrolling. A reload would swap in a
    /// recycled cell and lose an open rename.
    private func reconfigure(_ ids: Set<SidebarNodeID>) {
        guard !ids.isEmpty else { return }
        table.enumerateAvailableRowViews { rowView, index in
            guard self.rows.indices.contains(index), ids.contains(self.rows[index].id) else { return }
            let row = self.rows[index]
            if let rowView = rowView as? SidebarRowView {
                self.configureRowView(rowView, row: row)
            }
            if let cell = rowView.view(atColumn: 0) as? NSView {
                self.configureCell(cell, row: row)
            }
        }
    }

    // MARK: Selection

    /// Selects the rows `AppState` names: its selected worktrees and its
    /// selected remote session. A row the dock does not show is skipped.
    private func applyModelSelection() {
        let remote = appState.selectedRemoteSession.map {
            RemoteSessionIdentity.uuid(provider: $0.provider, sessionID: $0.sessionID)
        }
        let wanted = SidebarSelectionBridge.outlineIDs(
            selectedWorktreeIDs: appState.selectedWorktreeIDs, selectedRemoteSession: remote)
        var indexes = IndexSet()
        for (index, row) in rows.enumerated() where wanted.contains(row.id) {
            indexes.insert(index)
        }
        if indexes != table.selectedRowIndexes {
            table.selectRowIndexes(indexes, byExtendingSelection: false)
        }
    }

    /// A selection that changed since the last apply scrolls its first dock
    /// row into view: opening a subtree can push the dock past its cap.
    private func scrollNewSelectionIntoView() {
        let key = SelectionKey(worktrees: appState.selectedWorktreeIDs, remote: appState.selectedRemoteSession)
        defer { lastSelection = key }
        guard let previous = lastSelection, previous != key, let first = table.selectedRowIndexes.first else { return }
        table.scrollRowToVisible(first)
    }

    /// A user's selection: written to `AppState.selectedWorktreeIDs` as the
    /// SwiftUI dock's tags would write it, then mirrored straight back, since
    /// the `didSet` may route it. A ⌘- or ⇧-click extends the selection, so
    /// selected rows the dock does not show stay selected; a plain click
    /// replaces it.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingModelSelection else {
            suppressedSelectionNotificationCount += 1
            return
        }
        let selected = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }
        var ids = SidebarSelectionBridge.appStateIDs(for: selected)
        if !selectionModifiers().isDisjoint(with: [.command, .shift]) {
            let shown = Set(rows.map(\.id))
            ids.formUnion(appState.selectedWorktreeIDs.filter { !shown.contains(.worktree($0)) })
        }
        writeSelection(ids)
        isApplyingModelSelection = true
        applyModelSelection()
        isApplyingModelSelection = false
    }

    private func writeSelection(_ ids: Set<UUID>) {
        guard ids != appState.selectedWorktreeIDs else { return }
        appStateSelectionWriteCount += 1
        appState.selectedWorktreeIDs = ids
    }

    // MARK: NSTableViewDataSource and NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let entry = rows[row]
        let cell: NSTableCellView
        switch entry.kind {
        case .worktree:
            cell = (tableView.makeView(withIdentifier: WorktreeRowCell.reuseIdentifier, owner: self)
                as? WorktreeRowCell) ?? WorktreeRowCell()
        case .remoteSession:
            cell = (tableView.makeView(withIdentifier: RemoteSessionRowCell.reuseIdentifier, owner: self)
                as? RemoteSessionRowCell) ?? RemoteSessionRowCell()
        }
        configureCell(cell, row: entry)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = (tableView.makeView(withIdentifier: SidebarRowView.reuseIdentifier, owner: self)
            as? SidebarRowView) ?? SidebarRowView(frame: .zero)
        if rows.indices.contains(row) {
            configureRowView(rowView, row: rows[row])
        }
        return rowView
    }

    /// Every row view the table adds — fresh, reused, or shifted to a new
    /// row — takes its guide lines from the row it now shows.
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard let rowView = rowView as? SidebarRowView, rows.indices.contains(row) else { return }
        configureRowView(rowView, row: rows[row])
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return PinnedDockMetrics.rowHeight }
        switch rows[row].kind {
        case .worktree(let model): return WorktreeRowCell.height(for: model)
        case .remoteSession(let model): return RemoteSessionRowCell.height(for: model)
        }
    }

    // MARK: Cells

    /// Hands `cell` its model, its depth's inset and its controls' target.
    /// A descendant's content moves one indentation step per level, as
    /// `WorktreeRowView`'s `indentLevel` moves it, and its gutter pin with it.
    private func configureCell(_ cell: NSView, row: DockRow) {
        let id = row.id
        switch (row.kind, cell) {
        case (.worktree(let model), let cell as WorktreeRowCell):
            cell.leadingInset = Self.rowInset + CGFloat(row.depth) * SidebarNativeMetrics.indentation
            cell.pinButton.target = self
            cell.pinButton.action = #selector(pinClicked(_:))
            cell.plusButton.target = self
            cell.plusButton.action = #selector(nestedPlusClicked(_:))
            cell.toolTips.provider = { [weak self] target in self?.helpText(target, for: id) }
            if case .worktree(let worktreeID) = id {
                cell.onOpenPullRequest = { [weak self] in self?.openPullRequest(worktreeID) ?? false }
            }
            cell.configure(model)
        case (.remoteSession(let model), let cell as RemoteSessionRowCell):
            cell.leadingInset = Self.rowInset
            cell.toolTips.provider = { [weak self] target in self?.helpText(target, for: id) }
            cell.configure(model)
        default:
            break
        }
        applyHover(to: cell, id: id)
    }

    /// The row view's tint origin and guide lines: one line per level of a
    /// descendant's depth, as `WorktreeRowView` draws them, broken where the
    /// gutter pin shows — on hover, and always once pinned.
    private func configureRowView(_ rowView: SidebarRowView, row: DockRow) {
        var configuration = SidebarRowView.Configuration()
        configuration.contentOrigin = Self.rowInset
        if case .worktree(let model) = row.kind {
            configuration.guideCount = row.depth
            configuration.showsPinGap = (model.isPinned || hoverState.row == row.id) && !model.isMain
        }
        rowView.configuration = configuration
    }

    // MARK: Hover

    /// A dock row as the hover tracker sees it: its ID, in no section.
    func hoverRow(_ index: Int) -> (id: SidebarNodeID, section: SidebarNodeID?)? {
        guard rows.indices.contains(index) else { return nil }
        return (id: rows[index].id, section: nil)
    }

    /// The tracker's report: the `+` under the pointer arms the shared menu,
    /// and every row the table has takes the new hover. A recompute that finds
    /// nothing changed leaves the rows as they are.
    func hoverChanged(_ state: SidebarHoverTracker.State) {
        let previous = hoverState
        hoverState = state
        guard state != previous else { return }
        plusMenu.pointerMoved(
            from: previous.part == .plus ? previous.row : nil, to: state.part == .plus ? state.row : nil,
            in: table, anchor: { plusAnchor(for: $0) }, target: { plusTarget(for: $0) },
            appState: appState, sheets: sheets)
        applyHoverToAvailableRows()
    }

    /// Hands every row view the table has its pin gap, and every cell its
    /// hover.
    func applyHoverToAvailableRows() {
        table.enumerateAvailableRowViews { rowView, index in
            guard self.rows.indices.contains(index) else { return }
            let row = self.rows[index]
            if let rowView = rowView as? SidebarRowView {
                self.configureRowView(rowView, row: row)
            }
            if let cell = rowView.view(atColumn: 0) as? NSView {
                self.applyHover(to: cell, id: row.id)
            }
        }
    }

    /// The hovered row shows its pin and nested `+`, the control under the
    /// pointer its wash; the `+` whose menu is open stays shown.
    private func applyHover(to cell: NSView, id: SidebarNodeID) {
        let hovered = hoverState.row == id
        switch cell {
        case let cell as WorktreeRowCell:
            cell.setHovered(hovered)
            cell.setMenuOpen(plusMenu.isOpen(for: id, in: table))
            cell.setHoveredPart(hovered ? hoverState.part : .none)
        case let cell as RemoteSessionRowCell:
            cell.setHovered(hovered)
        default:
            break
        }
    }

    /// The nested `+` of a row the dock shows.
    private func plusAnchor(for id: SidebarNodeID) -> NSView? {
        guard let index = rows.firstIndex(where: { $0.id == id }),
              let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? WorktreeRowCell else {
            return nil
        }
        return cell.plusButton
    }

    /// Where a dock row's nested `+` creates: the row's repo, under the row.
    /// Nil for the main row and a scratch row, which offer none.
    private func plusTarget(for id: SidebarNodeID) -> SidebarPlusTarget? {
        guard case .worktree(let worktreeID) = id, let worktree = appState.findWorktree(id: worktreeID),
              worktree.status != .main, let repoID = worktree.repoID else { return nil }
        return SidebarPlusTarget(repoID: repoID, parent: worktreeID)
    }

    /// The text AppKit asks for when the pointer rests on a cell's badge,
    /// no-status mark or cross-repo suffix: the outline's own words.
    private func helpText(_ target: SidebarToolTips.Target, for id: SidebarNodeID) -> String? {
        let kind = rows.first { $0.id == id }?.kind
        switch (target, id, kind) {
        case (.suffix, .worktree(let worktreeID), .worktree(let model)?):
            guard let indicator = model.suffix else { return nil }
            return SidebarOutlineController.worktreeSuffixHelp(worktreeID, indicator: indicator, appState: appState)
        case (.noStatusMark, .worktree(let worktreeID), _):
            return NoStatusMark.rowHelp(
                terminals: appState.terminals[worktreeID] ?? [], sightings: appState.noStatusSightings)
        case (.crossRepo, .worktree(let worktreeID), _):
            return appState.findWorktree(id: worktreeID)?.repoID.flatMap { appState.repoName(for: $0) }
        case (.suffix, .remoteSession(let sessionID), .remoteSession(let model)?):
            guard let indicator = model.suffix else { return nil }
            return SidebarOutlineController.remoteSuffixHelp(sessionID, indicator: indicator, appState: appState)
        default:
            return nil
        }
    }

    // MARK: Row controls and clicks

    /// The worktree whose row `sender` sits in.
    private func rowWorktreeID(for sender: NSView) -> UUID? {
        let index = table.row(for: sender)
        guard rows.indices.contains(index), case .worktree(let id) = rows[index].id else { return nil }
        return id
    }

    /// The gutter pin, shown on hover and always once pinned: a click pins
    /// or unpins the row.
    @objc func pinClicked(_ sender: NSView) {
        guard let worktreeID = rowWorktreeID(for: sender),
              let worktree = appState.findWorktree(id: worktreeID) else { return }
        let state = appState
        let pinned = worktree.pinnedAt == nil
        Task { await state.setPinned(worktreeID: worktreeID, pinned: pinned) }
    }

    /// The nested `+`, through the outline's own press: a plain click creates
    /// a worktree with the default profile, ⌥-click opens the picker.
    @objc func nestedPlusClicked(_ sender: NSView) {
        guard let worktreeID = rowWorktreeID(for: sender), let target = plusTarget(for: .worktree(worktreeID)) else {
            return
        }
        plusMenu.press(owner: .worktree(worktreeID), anchor: sender, in: table, target: target,
                       appState: appState, sheets: sheets)
    }

    /// The table's click action: a click on a worktree row's PR glyph opens
    /// the pull request. Row clicks otherwise select through the table.
    @objc func tableClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseUp || event.type == .leftMouseDown else { return }
        openPullRequestIfClickedGlyph(row: table.clickedRow, at: table.convert(event.locationInWindow, from: nil))
    }

    /// - Parameter point: the click, in the table's coordinates.
    /// - Returns: whether the click opened a pull request.
    @discardableResult
    func openPullRequestIfClickedGlyph(row index: Int, at point: NSPoint) -> Bool {
        guard rows.indices.contains(index), case .worktree(let worktreeID) = rows[index].id,
              let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? WorktreeRowCell,
              cell.isPullRequestGlyph(at: cell.convert(point, from: table)) else { return false }
        return openPullRequest(worktreeID)
    }

    /// Opens the worktree's worst-state pull request, if it has one, as
    /// `WorktreeRowView.openPR` picks it.
    func openPullRequest(_ worktreeID: UUID) -> Bool {
        guard let binding = PRBindingPresentation.iconBinding(appState.effectivePRBindings(worktreeID: worktreeID)),
              let url = URL(string: binding.url) else { return false }
        openURL(url)
        return true
    }

    // MARK: Context menus

    /// The row's menu: the outline's, built from the same models.
    private func contextMenu(forRow index: Int) -> NSMenu? {
        guard rows.indices.contains(index) else { return nil }
        let row = rows[index]
        return SidebarMenus(appState: appState, defaults: defaults, host: self)
            .menu(for: SidebarNode(id: row.id, kind: row.nodeKind, children: [], isExpanded: false))
    }

    // MARK: Rename

    /// The inline editor `RenameableLabel` shows, in the dock's own row, with
    /// the rows held until the edit ends. One rename at a time: an open one is
    /// committed first.
    private func startRename(_ id: SidebarNodeID) {
        renameEditor?.close(commitPending: true)
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        table.scrollRowToVisible(index)
        guard let cell = table.view(atColumn: 0, row: index, makeIfNecessary: true) as? NSView & SidebarRenamableCell,
              let editor = SidebarOutlineController.makeRenameEditor(
                for: id, kind: rows[index].nodeKind, seed: nil, appState: appState) else { return }
        beginHold(.rename)
        renamingCell = cell
        renameEditor = editor
        editor.onFinished = { [weak self, weak editor] in self?.renameFinished(editor) }
        cell.beginRename(editor)
    }

    /// The edit is over: the cell still showing `editor` gets its label back,
    /// and the hold ends.
    private func renameFinished(_ editor: SidebarRenameEditor?) {
        guard let editor, editor === renameEditor else { return }
        if let cell = renamingCell as? SidebarRenamableCell, cell.renameEditor === editor {
            cell.endRename()
        }
        renamingCell = nil
        renameEditor = nil
        endHold(.rename)
    }

    // MARK: Drag and drop

    /// Only a pinned root drags, under the dock's own type: a descendant and a
    /// remote pin have no pin order to move.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard rows.indices.contains(row), rows[row].isPinnedRoot,
              case .worktree(let worktreeID) = rows[row].id else { return nil }
        let item = NSPasteboardItem()
        item.setString(worktreeID.uuidString, forType: .tbdDockPin)
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        beginHold(.drag)
    }

    /// The last hold ending applies the held rows now, so a drop's new order
    /// lands as the drag ends.
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dropPayloadCache = nil
        endHold(.drag)
    }

    /// A drag carrying dock pins may land in a gap between pinned roots; the
    /// table draws the line there. Anything else — the sidebar's own type
    /// above all — is refused.
    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let carried = cachedPayload(of: info), let gap = Self.rootGap(proposedRow: row, in: rows) else {
            return []
        }
        // A gap that would leave the order as it is takes no drop: no line,
        // and the drag slides back.
        let roots = shownRootIDs
        let before = gap.offset < roots.count ? roots[gap.offset] : nil
        guard Self.reorder(carried: carried, before: before, roots: roots) != nil else { return [] }
        if gap.row != row || dropOperation != .above {
            tableView.setDropRow(gap.row, dropOperation: .above)
        }
        return .move
    }

    /// The drop: the carried pins and the root the gap sits before, by ID,
    /// turned into offsets against the roots `AppState` holds now, and handed
    /// to `reorderPins`, whose `PinnedDockReorder` guard checks them once
    /// more. A drag holds the dock's rows, so a pin unpinned mid-drag can
    /// still show; a carried pin or an anchor that left refuses the drop.
    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let carried = Self.dockPayload(from: info.draggingPasteboard),
              let gap = Self.rootGap(proposedRow: row, in: rows) else { return false }
        let shownRoots = shownRootIDs
        let before = gap.offset < shownRoots.count ? shownRoots[gap.offset] : nil
        guard let move = Self.reorder(carried: carried, before: before, roots: currentRootIDs()) else {
            dockLogger.info(
                "Native dock drop of \(carried.count, privacy: .public) pin(s) not applied: the pins changed during the drag, or the order would not change")
            return false
        }
        if let hook = reorderPinsForTesting {
            hook(move.source, move.destination)
        } else {
            appState.reorderPins(fromOffsets: move.source, toOffset: move.destination)
        }
        return true
    }

    /// The pinned roots the dock shows, top to bottom.
    private var shownRootIDs: [UUID] {
        rows.compactMap { entry in
            guard entry.isPinnedRoot, case .worktree(let id) = entry.id else { return nil }
            return id
        }
    }

    /// The pinned roots as `AppState` holds them now: the list
    /// `reorderPins` checks its offsets against, derived the same way.
    private func currentRootIDs() -> [UUID] {
        PinnedDockContent.rows(allWorktrees: appState.allWorktrees, selectedIDs: [], children: { _ in [] })
            .map(\.worktree.id)
    }

    /// The gap between pinned roots a drop proposed above `proposedRow` lands
    /// in: the table row the line shows above, and how many roots sit above
    /// it — the destination offset `.onMove` would hand over. A gap inside a
    /// root's subtree moves down past the subtree, and a gap among the remote
    /// pins up to the end of the worktree pins, since only roots move. Nil
    /// when the dock shows no root.
    static func rootGap(proposedRow: Int, in rows: [DockRow]) -> (row: Int, offset: Int)? {
        guard rows.contains(where: \.isPinnedRoot) else { return nil }
        let worktreeCount = rows.firstIndex { !$0.isWorktree } ?? rows.count
        var gap = min(max(proposedRow, 0), worktreeCount)
        while gap < worktreeCount, rows[gap].depth > 0 {
            gap += 1
        }
        let offset = rows[..<gap].filter(\.isPinnedRoot).count
        return (gap, offset)
    }

    /// The `reorderPins` offsets that move `carried` to the gap before
    /// `before` — the end when nil — among `roots`. Nil when a carried pin or
    /// `before` is no longer one of `roots`, or when the move changes nothing.
    static func reorder(carried: [UUID], before: UUID?, roots: [UUID]) -> (source: IndexSet, destination: Int)? {
        var source = IndexSet()
        for id in carried {
            guard let index = roots.firstIndex(of: id) else { return nil }
            source.insert(index)
        }
        guard !source.isEmpty else { return nil }
        let destination: Int
        if let before {
            guard let index = roots.firstIndex(of: before) else { return nil }
            destination = index
        } else {
            destination = roots.count
        }
        guard let reordered = PinnedDockReorder.reordered(roots: roots, fromOffsets: source, toOffset: destination),
              reordered != roots else { return nil }
        return (source, destination)
    }

    /// The pins a drag carries: the ID in every pasteboard item under the
    /// dock's type, in pasteboard order, each once. Nil when there is none,
    /// as for the sidebar's own type.
    static func dockPayload(from pasteboard: NSPasteboard) -> [UUID]? {
        var seen: Set<UUID> = []
        var ids: [UUID] = []
        for item in pasteboard.pasteboardItems ?? [] {
            guard let string = item.string(forType: .tbdDockPin),
                  let id = UUID(uuidString: string), seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        return ids.isEmpty ? nil : ids
    }

    /// `dockPayload`, read once per drag.
    private func cachedPayload(of info: any NSDraggingInfo) -> [UUID]? {
        let sequence = info.draggingSequenceNumber
        if let cache = dropPayloadCache, cache.sequence == sequence {
            return cache.ids.isEmpty ? nil : cache.ids
        }
        let ids = Self.dockPayload(from: info.draggingPasteboard) ?? []
        dropPayloadCache = (sequence: sequence, ids: ids)
        return ids.isEmpty ? nil : ids
    }
}

/// What the dock's menus ask of it. The dock shows no headers, so nothing it
/// shows offers an expansion toggle or a repo's removal.
extension DockTableController: SidebarMenuHost {
    func beginRename(_ id: SidebarNodeID) {
        startRename(id)
    }

    func toggleExpansion(of id: SidebarNodeID) {}

    func present(_ sheet: NativeSidebarSheet) {
        sheets.present(sheet)
    }

    func confirmRemove(_ repo: Repo) {}
}

/// The native pinned dock's `NSTableView`: a context menu per row, a press on
/// a row's button that never starts a drag, and drags that stay moves
/// whatever modifier is held.
final class DockTableView: NSTableView {
    /// Kept alive as long as the table: the tracker owns the table's one
    /// tracking area, and a tracking area does not retain its owner.
    var hoverTracker: SidebarHoverTracker?

    /// The context menu for a row, built when the menu is asked for.
    var contextMenuProvider: ((Int) -> NSMenu?)?

    /// The row's menu, shown through `super` so the table draws its usual
    /// highlight around the right-clicked row.
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        menu = row >= 0 ? contextMenuProvider?(row) : nil
        guard menu != nil else { return nil }
        return super.menu(for: event)
    }

    /// A press on a row's pin toggle tracks the button and never starts a
    /// drag; a press anywhere else in a pinned root's row can.
    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        if isOnButton(mouseDownPoint) { return false }
        return super.canDragRows(with: rowIndexes, at: mouseDownPoint)
    }

    /// Pins only ever move: a modifier key held mid-drag would otherwise
    /// narrow the drag's `.move` mask to an operation the dock refuses. As in
    /// `SidebarOutlineView`, `NSTableView` adopts `NSDraggingSource`, so this
    /// is an override.
    override func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    /// Whether `point`, in the table's coordinates, lands on a button inside
    /// a row.
    func isOnButton(_ point: NSPoint) -> Bool {
        guard let superview else { return false }
        var view = hitTest(convert(point, to: superview))
        while let current = view, current !== self {
            if current is NSButton { return true }
            view = current.superview
        }
        return false
    }
}
