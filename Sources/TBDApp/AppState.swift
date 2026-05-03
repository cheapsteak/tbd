import AppKit
import Foundation
import SwiftUI
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState")

/// Transition state for a worktree being revived from the archived view.
/// Holds a snapshot of the `Worktree` so the row can keep rendering even
/// after the daemon removes it from `archivedWorktrees`.
enum ReviveState: Equatable {
    case inFlight(snapshot: Worktree)
    case done(snapshot: Worktree)

    var snapshot: Worktree {
        switch self {
        case .inFlight(let s), .done(let s): return s
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var repos: [Repo] = []
    @Published var worktrees: [UUID: [Worktree]] = [:]
    @Published var terminals: [UUID: [Terminal]] = [:]
    @Published var notes: [UUID: [Note]] = [:]
    @Published var notifications: [UUID: NotificationType?] = [:]
    @Published var selectedWorktreeIDs: Set<UUID> = [] {
        didSet {
            // If the List selected a repo header tag (not a worktree), treat it
            // as a repo selection and remove the ID from the worktree set.
            let repoIDs = Set(repos.map(\.id))
            let selectedRepoIDs = selectedWorktreeIDs.intersection(repoIDs)
            if !selectedRepoIDs.isEmpty {
                selectedWorktreeIDs.subtract(selectedRepoIDs)
                // selectRepo() already handles this; avoid overriding it
                return
            }

            // Remove deselected items from order
            selectionOrder.removeAll { !selectedWorktreeIDs.contains($0) }
            // Append newly selected items (maintains insertion order for cmd+click)
            for id in selectedWorktreeIDs where !selectionOrder.contains(id) {
                selectionOrder.append(id)
            }
            // Clear repo selection when a worktree is selected
            if !selectedWorktreeIDs.isEmpty {
                if let leaving = selectedRepoID { clearRevivingArchived(repoID: leaving) }
                selectedRepoID = nil
                recordNavigation(.worktrees(selectionOrder))
            }
        }
    }
    /// Tracks the order of selected worktrees for split view rendering (cmd+click order).
    @Published var selectionOrder: [UUID] = []
    /// Selected repo ID — set when a repo header is clicked, shows archived worktrees in content pane.
    @Published var selectedRepoID: UUID? = nil {
        didSet {
            if let old = oldValue, old != selectedRepoID {
                clearRevivingArchived(repoID: old)
            }
            guard selectedRepoID != oldValue, let id = selectedRepoID else { return }
            recordNavigation(.repo(id))
        }
    }

    // MARK: - Navigation history (back/forward)

    /// Back/forward state. Mutated only by the helpers in `AppState+Navigation.swift` —
    /// any change to `navigationIndex` or `navigationEntries` must be followed by
    /// `updateNavigationFlags()` to keep the published toolbar flags in sync.

    /// Published flags driving the toolbar back/forward buttons.
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false
    /// Recorded navigation entries (most recent at the end).
    var navigationEntries: [NavigationEntry] = []
    /// Index into `navigationEntries` of the currently-displayed view state, or -1 if none.
    var navigationIndex: Int = -1
    /// True while applying a back/forward entry, to suppress recording the resulting selection change.
    var isNavigating: Bool = false

    /// Refresh the @Published `canGoBack` / `canGoForward` flags from the index.
    /// Lives in the same file as the @Published properties so the `private(set)`
    /// setters are reachable.
    func updateNavigationFlags() {
        let back = navigationIndex > 0
        let forward = navigationIndex >= 0 && navigationIndex < navigationEntries.count - 1
        if back != canGoBack { canGoBack = back }
        if forward != canGoForward { canGoForward = forward }
    }
    /// Archived worktrees keyed by repo ID, fetched on demand.
    @Published var archivedWorktrees: [UUID: [Worktree]] = [:]

    /// Set briefly when a deep link lands on an archived worktree. The
    /// ArchivedWorktreesView observes this and scrolls/flashes the matching
    /// row, then clears the value after the flash animation completes.
    @Published var highlightedArchivedWorktreeID: UUID?

    /// Test seam: when set, replaces the daemon roundtrip for archived
    /// lookups in `navigateToArchivedWorktree(_:)`. Production code leaves
    /// this nil; tests assign a closure returning a deterministic worktree
    /// list.
    var archivedLookupOverride: ((UUID) async -> [Worktree])?

    /// True once `connectAndLoadInitialState()` has finished its initial
    /// `refreshAll()` and the worktree list is populated. Used by
    /// `navigateToWorktree(_:)` to detect cold-start clicks that arrive
    /// before the daemon RPC has returned.
    @Published var isInitialStateLoaded: Bool = false

    /// Buffers a deep-link target UUID when `.onOpenURL` fires before the
    /// initial state load completes. Drained at the end of
    /// `connectAndLoadInitialState()`. Internal-only — never written from
    /// outside the AppState extension that consumes it.
    var pendingDeepLinkID: UUID?

    /// The first selected worktree, if any.
    var selectedWorktree: Worktree? {
        guard let id = selectedWorktreeIDs.first else { return nil }
        return worktrees.values.flatMap { $0 }.first { $0.id == id }
    }

    /// All pinned terminals across all worktrees, sorted by pinnedAt.
    var pinnedTerminals: [Terminal] {
        terminals.values.flatMap { $0 }
            .filter { $0.pinnedAt != nil }
            .sorted { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }
    }

    /// Worktree IDs that have at least one terminal currently visible on screen.
    /// Includes selected worktrees (active tab visible) and worktrees with pinned terminals
    /// (always visible in either the active tab or the pinned dock).
    var visibleWorktreeIDs: Set<UUID> {
        var ids = selectedWorktreeIDs
        for terminal in pinnedTerminals {
            ids.insert(terminal.worktreeID)
        }
        return ids
    }

    @Published var dockRatio: CGFloat = 0.3 {
        didSet { UserDefaults.standard.set(Double(dockRatio), forKey: Self.dockRatioKey) }
    }
    /// Pixel size of the main terminal area (the SingleWorktreeView slot
    /// inside DockSplitView, excluding the pinned dock and file panel).
    /// Default matches the typical window: 1200 wide window − sidebar (~280) ≈ 920;
    /// 800 tall window − toolbar (~24) ≈ 776. Conservative fallback for the
    /// first RPC before the GeometryReader publishes a real value.
    @Published var mainAreaSize: CGSize = CGSize(width: 1120, height: 776) {
        didSet {
            guard mainAreaSize != oldValue else { return }
            scheduleMainAreaSizeBroadcast()
        }
    }
    /// Debounce token for broadcasting `mainAreaSize` changes to the daemon.
    /// Cancelled and re-scheduled on every change so we send one RPC per
    /// resize gesture rather than per AppKit layout pass.
    private var mainAreaSizeBroadcastTask: Task<Void, Never>?
    private var lastBroadcastCols: Int = 0
    private var lastBroadcastRows: Int = 0
    @Published var isConnected: Bool = false
    @Published var layouts: [UUID: LayoutNode] = [:] {
        didSet { persistLayouts() }
    }
    @Published var tabs: [UUID: [Tab]] = [:]
    @Published var activeTabIndices: [UUID: Int] = [:]
    @Published var repoFilter: UUID? = nil
    @Published var pendingWorktreeIDs: Set<UUID> = []
    @Published var suspendingTerminalIDs: Set<UUID> = []
    /// Closures registered by live TerminalPanelView instances to capture a screenshot.
    /// Keyed by terminal UUID. Populated in makeNSView, cleared on view disappear.
    var snapshotProviders: [UUID: () -> NSImage?] = [:]
    /// Visual screenshots taken at suspend-click time, shown while daemon works.
    /// Keyed by terminal UUID. Cleared when suspend completes.
    @Published var suspendingSnapshots: [UUID: NSImage] = [:]

    func setSuspendingSnapshot(_ image: NSImage, for id: UUID) {
        suspendingSnapshots[id] = image
    }

    func removeSuspendingSnapshot(for id: UUID) {
        suspendingSnapshots.removeValue(forKey: id)
    }
    @Published var editingWorktreeID: UUID? = nil
    @Published var isRenamingWorktree = false
    @Published var prStatuses: [UUID: PRStatus] = [:]
    @Published var claudeTokens: [ClaudeTokenWithUsage] = []
    @Published var globalDefaultClaudeTokenID: UUID? = nil
    @Published var historyActiveWorktrees: Set<UUID> = []
    @Published var historyLoadStates: [UUID: HistoryLoadState] = [:]
    @Published var selectedSessionIDs: [UUID: String] = [:]       // worktreeID → sessionId
    @Published var sessionTranscripts: [String: [ChatMessage]] = [:]  // sessionId → messages
    @Published var sessionTranscriptLoading: Set<String> = []

    /// Selected archived worktree per repo (left rail of the archived view's nested master-detail).
    @Published var selectedArchivedWorktreeIDs: [UUID: UUID] = [:]

    /// Worktrees the user just revived from the archived view. Keeps the row
    /// visible with a status indicator until the user navigates away from the
    /// archived section. Cleared by `AppState+Navigation` when the active
    /// sidebar selection moves elsewhere.
    @Published var revivingArchived: [UUID: ReviveState] = [:]

    /// Conductor for each repo (wildcard conductors expanded across all repos).
    @Published var conductorsByRepo: [UUID: Conductor] = [:]
    /// The conductor's terminal record, keyed by repo ID.
    @Published var conductorTerminalsByRepo: [UUID: Terminal] = [:]
    /// Current navigation suggestion from any conductor.
    @Published var conductorSuggestion: ConductorSuggestion? = nil
    /// Whether the conductor overlay is visible.
    @Published var showConductor: Bool = false
    /// Conductor overlay height — persisted. 0 means "use default (50% of parent)".
    @Published var conductorHeight: CGFloat = 0 {
        didSet { UserDefaults.standard.set(Double(conductorHeight), forKey: Self.conductorHeightKey) }
    }
/// Terminal IDs currently being recreated — prevents duplicate RPC calls.
    var recreatingTerminalIDs: Set<UUID> = []

    // Alert state for user feedback
    @Published var alertMessage: String? = nil
    @Published var alertIsError: Bool = false

    let daemonClient = DaemonClient()
    let tmuxBridge = TmuxBridge()
    lazy var cliInstallerCoordinator = CLIInstallerCoordinator(daemonClient: daemonClient)
    private var pollTimer: Timer?
    private var pollCycle = 0
    private var subscriptionTask: Task<Void, Never>?
    let notificationSoundPlayer = NotificationSoundPlayer()
    let macNotificationManager = MacNotificationManager()

    private static let layoutsKey = "com.tbd.app.layouts"
    private static let dockRatioKey = "com.tbd.app.dockRatio"
    private static let conductorHeightKey = "com.tbd.app.conductorHeight"

    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var focusObservers: [NSObjectProtocol] = []

    init() {
        restoreLayouts()
        if let saved = UserDefaults.standard.object(forKey: Self.dockRatioKey) as? Double {
            dockRatio = max(0.1, min(0.6, CGFloat(saved)))
        }
        if let savedHeight = UserDefaults.standard.object(forKey: Self.conductorHeightKey) as? Double {
            conductorHeight = max(100, min(800, CGFloat(savedHeight)))
        }
        startMemoryPressureMonitor()
        registerFocusObservers()
        Task {
            await connectAndLoadInitialState()
            startPolling()
        }
    }

    // Note: AppState is singleton-lifetime in this app, so we deliberately
    // omit a deinit that removes the focus observers — Swift 6 concurrency
    // would require Sendable on the observer tokens to touch them from a
    // nonisolated deinit, and the leak is bounded by app lifetime.

    /// Forward macOS app focus changes to the daemon. The daemon uses this to
    /// pause/resume the Claude usage poller while the app is in the background.
    /// `NotificationCenter.addObserver` does not require a bundle ID, so this
    /// is safe to call from an unbundled SPM executable.
    private func registerFocusObservers() {
        let center = NotificationCenter.default
        let active = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.daemonClient.setAppForegroundState(isForeground: true)
                } catch {
                    logger.warning("setAppForegroundState(true) failed: \(error)")
                }
            }
        }
        let resigned = center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.daemonClient.setAppForegroundState(isForeground: false)
                } catch {
                    logger.warning("setAppForegroundState(false) failed: \(error)")
                }
            }
        }
        focusObservers = [active, resigned]
    }

    /// Respond to system memory pressure by purging purgeable caches.
    private nonisolated func startMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard self != nil else { return }
            Task { @MainActor in
                logger.warning("Memory pressure detected — purging caches")
                // Flush bitmap caches on all windows
                for window in NSApp.windows {
                    window.displaysWhenScreenProfileChanges = true
                }
                // Trigger a GC pass on ObjC autoreleased objects
                autoreleasepool {}
            }
        }
        source.activate()
        // Store must happen on MainActor
        Task { @MainActor in
            self.memoryPressureSource = source
        }
    }

    // MARK: - Layout Persistence

    private func persistLayouts() {
        guard let data = try? JSONEncoder().encode(layouts) else { return }
        UserDefaults.standard.set(data, forKey: Self.layoutsKey)
    }

    private func restoreLayouts() {
        guard let data = UserDefaults.standard.data(forKey: Self.layoutsKey),
              let restored = try? JSONDecoder().decode([UUID: LayoutNode].self, from: data) else { return }
        layouts = restored
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        stopSubscription()
    }

    /// Start listening for real-time state deltas from the daemon.
    func startSubscription() {
        subscriptionTask?.cancel()
        subscriptionTask = Task { [weak self] in
            guard let self else { return }
            await self.daemonClient.subscribe { [weak self] delta in
                Task { @MainActor [weak self] in
                    self?.handleDelta(delta)
                }
            }
            // Subscription disconnected — nil out so poll loop restarts it
            await MainActor.run { self.subscriptionTask = nil }
        }
    }

    func stopSubscription() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
    }

    func handleDelta(_ delta: StateDelta) {
        switch delta {
        case .notificationReceived(let notification):
            handleNotificationDelta(notification)
        case .claudeTokenUsageUpdated(let usage):
            applyClaudeTokenUsageDelta(usage)
        case .claudeTokensChanged:
            Task { [weak self] in await self?.refreshClaudeTokens() }
        default:
            break
        }
    }

    /// Update the in-place usage entry for a single Claude token. If no match,
    /// silently ignore — the next full refresh will pick it up.
    private func applyClaudeTokenUsageDelta(_ usage: ClaudeTokenUsage) {
        guard let idx = claudeTokens.firstIndex(where: { $0.token.id == usage.tokenID }) else {
            return
        }
        let existing = claudeTokens[idx]
        claudeTokens[idx] = ClaudeTokenWithUsage(token: existing.token, usage: usage)
    }

    private func handleNotificationDelta(_ notification: NotificationDelta) {
        let visible = visibleWorktreeIDs
        guard !visible.contains(notification.worktreeID) else { return }

        // Update local notification state
        notifications[notification.worktreeID] = notification.type

        // Fire sound + macOS notification
        notificationSoundPlayer.playIfEnabled()
        macNotificationManager.postIfEnabled(
            worktreeID: notification.worktreeID,
            message: notification.message,
            worktrees: allWorktrees
        )
    }

    private var allWorktrees: [Worktree] {
        worktrees.values.flatMap { $0 }
    }

    /// Poll daemon for state changes every 2 seconds.
    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isConnected {
                    // Try to start the daemon if socket doesn't exist
                    if !FileManager.default.fileExists(atPath: TBDConstants.socketPath) {
                        await self.startDaemonAndConnect()
                    } else {
                        let didConnect = await self.daemonClient.connect()
                        self.isConnected = didConnect
                    }
                    if !self.isConnected { return }
                }
                await self.refreshAll()
                if self.subscriptionTask == nil || self.subscriptionTask?.isCancelled == true {
                    self.startSubscription()
                }
                self.pollCycle += 1
                if self.pollCycle % 15 == 0 {
                    await self.refreshPRStatuses()
                }
            }
        }
    }

    // MARK: - Connection

    /// Connect to the daemon and fetch initial state.
    /// The daemon client will attempt to auto-start tbdd if not running.
    func connectAndLoadInitialState() async {
        let didConnect = await daemonClient.connect()
        isConnected = didConnect
        if didConnect {
            await refreshAll()
            await refreshClaudeTokens()
            startSubscription()
            await refreshPRStatuses()
            Task {
                try? await daemonClient.worktreeSelectionChanged(
                    selectedWorktreeIDs: selectedWorktreeIDs
                )
            }
        } else {
            logger.warning("Could not connect to daemon — is tbdd running?")
        }
        isInitialStateLoaded = true
        if let pendingID = pendingDeepLinkID {
            pendingDeepLinkID = nil
            navigateToWorktree(pendingID)
        }
        Task { [weak self] in
            guard let self else { return }
            await self.cliInstallerCoordinator.checkOnLaunch()
        }
    }

    /// Menu entry point — install or refresh the `tbd` CLI symlink.
    func installCLITool() async {
        await cliInstallerCoordinator.runFromMenu()
    }

    /// Launch the daemon process and connect.
    func startDaemonAndConnect() async {
        // Check if daemon is already running (PID file + process alive)
        let pidPath = TBDConstants.pidFilePath
        if let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8),
           let pid = pid_t(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
           kill(pid, 0) == 0 {
            // Daemon is running, just connect
            await connectAndLoadInitialState()
            return
        }

        // Find TBDDaemon binary next to this executable
        let selfPath = ProcessInfo.processInfo.arguments.first ?? ""
        let siblingPath = (selfPath as NSString).deletingLastPathComponent + "/TBDDaemon"

        let candidates = [
            siblingPath,
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("TBDDaemon").path,
        ].compactMap { $0 }

        var tbddPath: String?
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                tbddPath = path
                break
            }
        }

        guard let path = tbddPath else {
            showAlert("Could not find TBDDaemon binary", isError: true)
            return
        }

        logger.info("Starting daemon from: \(path)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.standardOutput = FileHandle(forWritingAtPath: "/tmp/tbdd.log") ?? .nullDevice
        process.standardError = FileHandle(forWritingAtPath: "/tmp/tbdd.log") ?? .nullDevice
        do {
            try process.run()
        } catch {
            showAlert("Failed to start daemon: \(error)", isError: true)
            return
        }

        // Wait for socket
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(200))
            if FileManager.default.fileExists(atPath: TBDConstants.socketPath) {
                break
            }
        }

        await connectAndLoadInitialState()
    }

    // MARK: - Refresh

    /// Refresh all state from the daemon.
    func refreshAll() async {
        await refreshRepos()
        await refreshWorktrees()
        await refreshNotifications()
        await refreshConductors()
    }

    /// Refresh the repo list. Only updates if data changed.
    func refreshRepos() async {
        do {
            let fetchedRepos = try await daemonClient.listRepos()
            if fetchedRepos != repos {
                repos = fetchedRepos
            }
        } catch {
            logger.error("Failed to list repos: \(error)")
            handleConnectionError(error)
        }
    }

    /// Refresh worktrees for all repos (or a specific repo).
    /// Fetches both active and main worktrees.
    func refreshWorktrees(repoID: UUID? = nil) async {
        do {
            // Single RPC — fetch all non-archived worktrees, filter client-side
            let allWts = try await daemonClient.listWorktrees(repoID: repoID)
            let fetched = allWts.filter { $0.status != .archived }

            if let repoID {
                // Preserve optimistic placeholders the daemon doesn't know about yet
                let placeholders = (worktrees[repoID] ?? []).filter { pendingWorktreeIDs.contains($0.id) }
                let merged = fetched + placeholders
                if merged != worktrees[repoID] ?? [] {
                    worktrees[repoID] = merged
                }
            } else {
                var grouped: [UUID: [Worktree]] = [:]
                for wt in fetched {
                    grouped[wt.repoID, default: []].append(wt)
                }
                // Preserve optimistic placeholders the daemon doesn't know about yet
                for (rid, wts) in worktrees {
                    for wt in wts where pendingWorktreeIDs.contains(wt.id) {
                        grouped[rid, default: []].append(wt)
                    }
                }
                if grouped != worktrees {
                    worktrees = grouped
                }
            }

            // Single RPC — fetch all terminals, group client-side
            let allTerminals = try await daemonClient.listTerminals()
            let terminalsByWorktree = Dictionary(grouping: allTerminals, by: { $0.worktreeID })
            let visibleWorktreeIDs = Set(fetched.map(\.id))
            for wtID in visibleWorktreeIDs {
                let fetched = terminalsByWorktree[wtID] ?? []
                let existing = terminals[wtID] ?? []
                if fetched != existing {
                    terminals[wtID] = fetched
                    reconcileTabs(worktreeID: wtID, terminals: fetched)
                }
            }

            // Fetch all notes, group client-side
            let allNotes = try await daemonClient.listNotes()
            let notesByWorktree = Dictionary(grouping: allNotes, by: { $0.worktreeID })
            for wtID in visibleWorktreeIDs {
                let fetched = notesByWorktree[wtID] ?? []
                let existing = notes[wtID] ?? []
                if fetched != existing {
                    notes[wtID] = fetched
                    reconcileNoteTabs(worktreeID: wtID, notes: fetched)
                }
            }
        } catch {
            logger.error("Failed to list worktrees: \(error)")
            handleConnectionError(error)
        }
    }

    /// Refresh terminals for a specific worktree. Only updates if data changed.
    func refreshTerminals(worktreeID: UUID) async {
        do {
            let fetched = try await daemonClient.listTerminals(worktreeID: worktreeID)
            let existing = terminals[worktreeID] ?? []
            if fetched != existing {
                terminals[worktreeID] = fetched
                reconcileTabs(worktreeID: worktreeID, terminals: fetched)
            }
        } catch {
            logger.error("Failed to list terminals for worktree \(worktreeID): \(error)")
            handleConnectionError(error)
        }
    }

    /// Reconcile tabs with the current terminal list for a worktree.
    /// Removes tabs whose root terminal no longer exists. Adds tabs for
    /// terminals that aren't already represented (either as a tab root or
    /// embedded in another tab's split layout).
    private func reconcileTabs(worktreeID: UUID, terminals: [Terminal]) {
        var currentTabs = tabs[worktreeID] ?? []
        let terminalIDs = Set(terminals.map(\.id))

        // 1. Remove tabs whose root terminal no longer exists,
        //    and clean up their persisted layouts.
        currentTabs.removeAll { tab in
            if case .terminal(let id) = tab.content, !terminalIDs.contains(id) {
                layouts.removeValue(forKey: tab.id)
                return true
            }
            return false
        }

        // 2. Now collect terminal IDs from surviving tabs' layouts.
        //    This must happen AFTER pruning so that dead tabs' children
        //    don't mask still-alive terminals that need new tabs.
        var terminalIDsInLayouts = Set<UUID>()
        for tab in currentTabs {
            if let layout = layouts[tab.id] {
                for id in layout.allTerminalIDs() {
                    terminalIDsInLayouts.insert(id)
                }
            } else {
                if case .terminal(let id) = tab.content {
                    terminalIDsInLayouts.insert(id)
                }
            }
        }

        // 3. Add tabs for terminals not already in any surviving layout.
        for terminal in terminals where !terminalIDsInLayouts.contains(terminal.id) {
            currentTabs.append(Tab(id: terminal.id, content: .terminal(terminalID: terminal.id)))
        }

        tabs[worktreeID] = currentTabs
    }

    /// Reconcile note tabs — remove tabs whose note no longer exists,
    /// add tabs for notes not already represented.
    private func reconcileNoteTabs(worktreeID: UUID, notes: [Note]) {
        var currentTabs = tabs[worktreeID] ?? []
        let noteIDs = Set(notes.map(\.id))

        // Collect note IDs already in tabs
        var noteIDsInTabs = Set<UUID>()
        currentTabs.removeAll { tab in
            if case .note(let id) = tab.content {
                if !noteIDs.contains(id) {
                    layouts.removeValue(forKey: tab.id)
                    return true
                }
                noteIDsInTabs.insert(id)
            }
            return false
        }

        // Add tabs for notes not already represented
        for note in notes where !noteIDsInTabs.contains(note.id) {
            currentTabs.append(Tab(id: note.id, content: .note(noteID: note.id), label: note.title))
        }

        tabs[worktreeID] = currentTabs
    }

    /// Poll all cached PR statuses from the daemon (background, every ~30s).
    func refreshPRStatuses() async {
        do {
            let fetched = try await daemonClient.listPRStatuses()
            // Only update if changed to avoid unnecessary SwiftUI redraws
            if fetched != prStatuses {
                prStatuses = fetched
            }
        } catch {
            logger.error("Failed to list PR statuses: \(error)")
            handleConnectionError(error)
        }
    }

    /// Trigger an immediate PR refresh for one worktree (on-select).
    func refreshPRStatus(worktreeID: UUID) async {
        do {
            let status = try await daemonClient.refreshPRStatus(worktreeID: worktreeID)
            if status != prStatuses[worktreeID] {
                prStatuses[worktreeID] = status
            }
        } catch {
            logger.error("Failed to refresh PR status for \(worktreeID): \(error)")
            handleConnectionError(error)
        }
    }

    /// Refresh unread notifications from the daemon.
    /// Notifications for currently visible worktrees (selected or pinned) are
    /// automatically marked as read so the badge never appears while the user
    /// is looking at the terminal.
    func refreshNotifications() async {
        do {
            let fetched = try await daemonClient.listNotifications()

            // Auto-mark-as-read for worktrees the user is currently looking at
            let visible = visibleWorktreeIDs
            let toMarkRead = fetched.keys.filter { visible.contains($0) }
            for worktreeID in toMarkRead {
                do {
                    try await daemonClient.markNotificationsRead(worktreeID: worktreeID)
                } catch {
                    logger.warning("Failed to auto-mark-read for \(worktreeID): \(error)")
                }
            }

            // Only include notifications for non-visible worktrees in UI state
            let filtered = fetched.filter { !visible.contains($0.key) }
            if filtered != notifications.compactMapValues({ $0 }) {
                var updated: [UUID: NotificationType?] = [:]
                for (id, type) in filtered {
                    updated[id] = type
                }
                notifications = updated
            }
        } catch {
            logger.error("Failed to list notifications: \(error)")
            handleConnectionError(error)
        }
    }

    // MARK: - Conductors

    /// Refresh conductor state from the daemon.
    func refreshConductors() async {
        do {
            let conductors = try await daemonClient.listConductors()

            // Fetch all terminals to find conductor terminals (conductor worktrees
            // are excluded from worktree.list, so self.terminals doesn't contain them)
            let allTerminals = try await daemonClient.listTerminals()
            let terminalsById = Dictionary(allTerminals.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

            // Build conductorsByRepo: expand ["*"] conductors across all repo IDs
            var byRepo: [UUID: Conductor] = [:]
            var termByRepo: [UUID: Terminal] = [:]
            let repoIDs = repos.map(\.id)

            for conductor in conductors {
                let matchingRepoIDs: [UUID]
                if conductor.repos.contains("*") {
                    matchingRepoIDs = repoIDs
                } else {
                    matchingRepoIDs = conductor.repos.compactMap { UUID(uuidString: $0) }
                }
                for repoID in matchingRepoIDs {
                    if byRepo[repoID] == nil {  // first match wins
                        byRepo[repoID] = conductor
                        if let termID = conductor.terminalID,
                           let term = terminalsById[termID] {
                            termByRepo[repoID] = term
                        }
                    }
                }
            }

            if byRepo != conductorsByRepo { conductorsByRepo = byRepo }
            if termByRepo != conductorTerminalsByRepo { conductorTerminalsByRepo = termByRepo }

            // Update suggestion from the conductor matching the current selection
            let newSuggestion: ConductorSuggestion? = {
                guard let selectedWt = selectedWorktree,
                      let conductor = byRepo[selectedWt.repoID] else { return nil }
                return conductor.suggestion
            }()
            if newSuggestion != conductorSuggestion { conductorSuggestion = newSuggestion }
        } catch {
            if !(error is DaemonClientError) {
                logger.error("Failed to refresh conductors: \(error)")
            }
        }
    }

    /// The conductor for the repo of the currently selected worktree.
    var currentConductor: Conductor? {
        guard let selectedWt = selectedWorktree else { return nil }
        return conductorsByRepo[selectedWt.repoID]
    }

    /// Whether a conductor is active (exists and has a terminal) for the current repo.
    var conductorActive: Bool {
        guard let conductor = currentConductor else { return false }
        return conductor.terminalID != nil
    }

    /// The conductor's terminal for the currently selected repo.
    var currentConductorTerminal: Terminal? {
        guard let selectedWt = selectedWorktree else { return nil }
        return conductorTerminalsByRepo[selectedWt.repoID]
    }

    /// Derive a conductor name from a repo's display name.
    /// Lowercases, replaces non-alphanumeric chars with hyphens, trims leading/trailing hyphens.
    static func conductorName(from repoName: String) -> String {
        let cleaned = repoName
            .lowercased()
            .replacing(/[^a-z0-9]+/, with: "-")
        let truncated = String(cleaned.prefix(64))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return truncated.isEmpty ? "conductor" : truncated
    }

    /// UserDefaults key for the WIP terminal-auto-resize feature. Off by
    /// default — the feature broadcasts main-area pixel size to the daemon
    /// and resizes every tracked tmux window on app resize / terminal
    /// create. See `mainAreaTerminalSize()` and `scheduleMainAreaSizeBroadcast()`
    /// for the two enforcement points. Settings UI toggle lives in the
    /// "Experimental" section of the General settings tab.
    static let terminalAutoResizeKey = "enableTerminalAutoResize"

    /// Whether the WIP main-area resize broadcast is enabled. Default false.
    private var terminalAutoResizeEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.terminalAutoResizeKey)
    }

    /// Convert the current `mainAreaSize` (pixels) into tmux cell dimensions
    /// using SwiftTerm's font metrics. Floors at the tmux minimum (80x24) so
    /// degenerate window sizes during launch never produce a too-small pane.
    /// Returns `(nil, nil)` when the auto-resize feature flag is off so the
    /// daemon's `cols ?? TmuxManager.defaultCols` / `rows ?? defaultRows`
    /// fallback fires (220×50). Returning `(0, 0)` would NOT trigger the
    /// fallback — `Optional.some(0)` is non-nil — and tmux would drop back
    /// to its own 80×24 default with the un-reflowable hard-wrapped
    /// scrollback that #73 introduced these defaults to prevent.
    func mainAreaTerminalSize() -> (cols: Int?, rows: Int?) {
        guard terminalAutoResizeEnabled else { return (nil, nil) }
        let cell = TBDTerminalView.cellDimensions(for: TBDTerminalView.defaultMonospaceFont)
        guard cell.width > 0, cell.height > 0 else { return (80, 24) }
        let cols = max(80, Int(mainAreaSize.width / cell.width))
        let rows = max(24, Int(mainAreaSize.height / cell.height))
        return (cols, rows)
    }

    /// Debounced RPC: tell the daemon the main area resized so it can resize
    /// every tracked tmux window. Coalesces rapid resize events into a single
    /// RPC ~300ms after the user stops dragging the window edge.
    private func scheduleMainAreaSizeBroadcast() {
        // Belt-and-suspenders: `mainAreaTerminalSize()` already returns
        // (nil, nil) when the flag is off, but this also avoids spinning up
        // the debounce Task and the noop diff against `lastBroadcastCols/Rows`
        // for every mainAreaSize change while disabled.
        guard terminalAutoResizeEnabled else { return }
        mainAreaSizeBroadcastTask?.cancel()
        let (cols, rows) = mainAreaTerminalSize()
        guard let cols, let rows else { return }
        // Skip noop broadcasts: same cell dims as the previous send.
        guard cols != lastBroadcastCols || rows != lastBroadcastRows else { return }
        mainAreaSizeBroadcastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            guard !Task.isCancelled, let self else { return }
            do {
                try await self.daemonClient.setMainAreaSize(cols: cols, rows: rows)
                self.lastBroadcastCols = cols
                self.lastBroadcastRows = rows
            } catch {
                logger.warning("setMainAreaSize broadcast failed: \(error)")
            }
        }
    }

    /// One-click conductor: setup (if needed) + start + show overlay.
    func ensureConductorRunning() async {
        guard let selectedWt = selectedWorktree else { return }
        let repoID = selectedWt.repoID

        do {
            if let existing = conductorsByRepo[repoID] {
                // Conductor exists — start it if not running
                if existing.terminalID == nil {
                    _ = try await daemonClient.conductorStart(name: existing.name)
                }
            } else {
                // No conductor — setup + start
                guard let repo = repos.first(where: { $0.id == repoID }) else { return }
                let name = Self.conductorName(from: repo.displayName)
                _ = try await daemonClient.conductorSetup(name: name, repos: [repoID.uuidString])
                _ = try await daemonClient.conductorStart(name: name)
            }
            // Refresh worktrees first so terminals dict is populated,
            // then refresh conductors to find the new terminal
            await refreshWorktrees()
            await refreshConductors()
            showConductor = true
        } catch {
            showAlert("Conductor error: \(error.localizedDescription)", isError: true)
        }
    }
}
