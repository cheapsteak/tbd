import AppKit
import Observation
import os
import TBDShared

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
///    held structure lands when the last hold ends. A drag's hold ends in
///    `draggingSession(_:endedAt:)`, which applies it at once.
///
/// The outline is the only writer of its own structure and expansion: the
/// delegate refuses every expand and collapse the controller did not ask for,
/// so the outline never drifts from the tree the next diff starts from.
/// Expanded state lives where the SwiftUI sidebar keeps it, and chevron clicks
/// write it there.
///
/// The class is split by concern: this file holds its state, the view, the
/// public surface, the update loop and the scratch-directory cache;
/// `+Apply` applies trees, `+DataSource` answers the outline and configures
/// cells, `+Selection` mirrors selection both ways, `+Expansion` runs
/// header actions, chevrons and reveal, `+Interaction` runs hover, the
/// row and header controls, inline rename, context menus, sheets and the
/// tooltip bubble, and `+Drag` runs drag and drop.
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
    /// carrying the latest row models. Written only by the apply.
    var tree = SidebarTree()

    var isHoldingStructure: Bool { !holds.isEmpty }

    // MARK: Test seams

    /// Builds run so far: what a coalescing test counts.
    private(set) var buildCount = 0
    /// Applies that fell back to `reloadData` because the row count disagreed
    /// with the tree. Written only by the controller.
    var fallbackReloadCount = 0
    /// Stands in for `SidebarTreeDiff.update` so a test can apply a wrong
    /// update and watch the fallback catch it.
    var diffForTesting: ((SidebarTree, SidebarTree) -> OutlineUpdate)?
    /// The update the last structural apply ran, for a failing test to print.
    var lastAppliedUpdate: OutlineUpdate?
    /// Each row view configured since the last apply began, and the row it
    /// was configured for: what a failing test prints to tell the view it
    /// configured from the view the outline shows.
    var configuredRowViews: [ObjectIdentifier: SidebarNodeID] = [:]

    // MARK: State

    var items = SidebarItemCache()
    private(set) var holds: Set<HoldReason> = []
    var hasLoaded = false
    private var rebuildScheduled = false
    /// True while the controller itself expands, collapses or reloads, the
    /// only time the delegate lets the outline change its expansion.
    var isApplyingStructure = false
    /// The options the shown tree was built with.
    private var options: SidebarBuildOptions
    /// `AppState.chevronBeforeProjectNameKey`: which side of a section title
    /// its chevron sits on, and with it the column every title and row uses.
    /// Layout only, so a change reconfigures the cells instead of rebuilding.
    var chevronBeforeTitle: Bool

    /// True for the whole of an apply, and while the controller mirrors
    /// `AppState`'s selection: the outline's selection notifications then are
    /// the controller's own doing and are not written back.
    var isApplyingModelSelection = false
    /// Writes the outline made to `AppState.selectedWorktreeIDs`. Written
    /// only by the controller.
    var appStateSelectionWriteCount = 0
    /// Selection notifications the guard kept from being written back: what
    /// a test counts to prove the guard ran. Written only by the controller.
    var suppressedSelectionNotificationCount = 0

    /// `SidebarView`'s reveal state, mirrored: the selection reveal's last
    /// value and whether the first one has run, the Ended reveal's last key,
    /// and a pending scroll target taken from `AppState` for this apply.
    var lastSelectionReveal: SidebarGroupReveal?
    var hasSeenSelectionReveal = false
    var hasRevealedInitialSelection = false
    var lastEndedRevealKey: EndedRevealKey?
    var hasSeenEndedRevealKey = false
    var pendingScrollTarget: UUID?

    /// What re-evaluates the Ended reveal: a new selection event, or the
    /// option turning on. `SidebarView.EndedRevealKey`'s twin.
    struct EndedRevealKey: Equatable {
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

    // MARK: Interaction state (`+Interaction`)

    /// Drives the hover tracker's 80 ms section debounce.
    let hoverClock: any Clock<Duration>
    /// Made with the view; the outline keeps it alive.
    var hoverTracker: SidebarHoverTracker?
    /// What the pointer was last reported over.
    var hoverState = SidebarHoverTracker.State()
    /// Laid over the scroll view, above every row.
    let tooltipOverlay = RowTooltipOverlay(frame: .zero)
    /// The `+` menu every repo header and worktree row shares.
    let plusMenu = SidebarPlusMenu()
    /// The row being renamed, its editor, and the cell showing it.
    var renamingID: SidebarNodeID?
    var renameEditor: SidebarRenameEditor?
    weak var renamingCell: NSView?
    /// The needs-auth popover while it is open.
    var authPopover: NSPopover?
    /// The sheet slot `NativeSidebarView` presents with SwiftUI.
    let sheets: NativeSidebarSheetPresenter
    /// Opens a pull request's page; tests hand in a recorder.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    // MARK: Drag state (`+Drag`)

    /// Where a drop decision looks up the shown tree. Built once per apply,
    /// so the drag path, which asks on every pointer move, never builds one.
    var dropIndex = SidebarDropIndex(tree: SidebarTree())
    /// True from a drag session's `willBeginAt` to its `endedAt`. The outline
    /// then expands nothing, the controller's own `expandItem` included, so
    /// a collapsed section never springs open under a drag.
    var isDragSessionActive = false
    /// The row showing the nest highlight.
    var nestTargetID: SidebarNodeID?
    /// The rows a drag carries, as read from its pasteboard, keyed by the
    /// drag's sequence number: `validateDrop` runs on every pointer move and
    /// reads the pasteboard once per drag.
    var dropPayloadCache: (sequence: Int, ids: [UUID])?
    /// Laid over the scroll view, below the tooltip bubble.
    let dropIndicator = SidebarDropIndicatorView(frame: .zero)

    static let signposter = OSSignposter(subsystem: "com.tbd.app", category: "native-sidebar")

    /// - Parameters:
    ///   - scratchDirectoryProbe: answers whether a scratch directory exists.
    ///     Runs off the main thread; tests hand in a fixed answer.
    ///   - sheets: the slot the SwiftUI wrapper presents sheets from; a
    ///     controller mounted on its own gets one of its own.
    ///   - clock: the hover tracker's clock, for its 80 ms debounce.
    init(
        appState: AppState,
        defaults: UserDefaults,
        scratchDirectoryProbe: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        sheets: NativeSidebarSheetPresenter? = nil,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.appState = appState
        self.defaults = defaults
        self.scratchDirectoryProbe = scratchDirectoryProbe
        self.sheets = sheets ?? NativeSidebarSheetPresenter()
        self.hoverClock = clock
        self.options = SidebarBuildOptions(defaults: defaults)
        self.chevronBeforeTitle = SidebarOutlineController.storedChevronBeforeTitle(defaults)
        super.init(nibName: nil, bundle: nil)
        // The notification arrives on whichever thread wrote the defaults.
        // The weak reference is read on the main thread, so the controller is
        // never retained, and so never released, anywhere else.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { [weak self] _ in
            SidebarOutlineController.performOnMain { self?.defaultsDidChange() }
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
        // The default since macOS 10.12, stated because `SidebarItemCache`
        // relies on it: the outline retains every item it still references,
        // so pruning the cache never frees an item under it.
        outline.stronglyReferencesItems = true
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

        // The tooltip bubble and the drop's insertion line float over the
        // scroll view, so they never join the outline's own subviews.
        let container = NSView(frame: .zero)
        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
        dropIndicator.frame = container.bounds
        dropIndicator.autoresizingMask = [.width, .height]
        tooltipOverlay.frame = container.bounds
        tooltipOverlay.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)
        container.addSubview(dropIndicator)
        container.addSubview(tooltipOverlay)
        view = container
        installInteractions()
        installDragAndDrop()
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
        // Nothing is hovered under a drag; the next pointer move recomputes.
        if reason == .drag { hoverTracker?.clear() }
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
        var renameRequest: RenameRequest?
        let latest: SidebarTree = withObservationTracking { () -> SidebarTree in
            // Reveals write `AppState` before the tracking is installed, so
            // their writes schedule nothing, and the build below sees them.
            self.performReveals(options: SidebarBuildOptions(defaults: store))
            options = SidebarBuildOptions(defaults: store)
            scratchPaths = SidebarOutlineController.unpromotedScratchPaths(state.scratchWorktrees)
            // The selection the apply mirrors into the outline.
            _ = state.selectedWorktreeIDs
            _ = state.selectedRemoteSession
            let built = SidebarTreeBuilder.build(state, options: options, directoryExists: { exists[$0] ?? true })
            // Rename-on-create: taken, and cleared, before the tracking is
            // installed, like the reveals; the rename starts after the apply.
            // A row not shown yet leaves the request pending.
            renameRequest = self.takeRenameRequest(in: built)
            return built
        } onChange: { [weak self] in
            // On the writing thread; read the weak reference on the main one.
            SidebarOutlineController.performOnMain { self?.scheduleRebuild() }
        }
        self.options = options
        buildCount += 1
        // Anything scheduled while building is covered by this build; a change
        // after the tracking re-armed schedules afresh.
        rebuildScheduled = false
        Self.signposter.endInterval("rebuild", interval)
        refreshScratchDirectories(scratchPaths)
        apply(latest)
        if let renameRequest {
            startRename(.worktree(renameRequest.id), seed: renameRequest.seed,
                        commitOpenEdit: !renameRequest.handsOver)
        }
    }

    /// `AppState` as it stands now, built outside the update loop: no
    /// reveals, no tracking, nothing applied. What `acceptDrop` checks a drop
    /// against, since a drag holds the shown structure and the shown tree
    /// may still carry rows the model has dropped.
    func currentTree() -> SidebarTree {
        let exists = scratchDirectoryExists
        return SidebarTreeBuilder.build(
            appState, options: SidebarBuildOptions(defaults: defaults), directoryExists: { exists[$0] ?? true })
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
        // The disk is read off the main thread, and the answer is taken on it
        // by a main-actor task. A detached task holding the controller across
        // that hop would release it off the main thread when it resumed, and
        // if that were the last reference the controller and its views would
        // be deallocated there.
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { () -> [String: Bool] in
                var found: [String: Bool] = [:]
                for path in paths { found[path] = probe(path) }
                return found
            }.value
            self?.scratchDirectoriesProbed(found, for: paths)
        }
    }

    private func scratchDirectoriesProbed(_ found: [String: Bool], for paths: Set<String>) {
        guard paths == probedScratchPaths else { return }
        let changed = found.contains { path, exists in (scratchDirectoryExists[path] ?? true) != exists }
        scratchDirectoryExists = found
        if changed { scheduleRebuild() }
    }
}
