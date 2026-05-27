import AppKit
import Combine
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

struct TabCloseContext: Equatable {
    let worktreeID: UUID
    let tabID: UUID
}

@MainActor
final class AppState: ObservableObject {
    /// Reference to the global appearance settings, wired by `TBDAppMain`
    /// after both StateObjects are constructed. Used by
    /// `mainAreaTerminalSize()` to compute initial tmux pane dimensions
    /// from the user's current font, before any `TBDTerminalView` exists.
    /// Plain (non-weak) optional — `AppState` and `AppearanceSettings` share
    /// the app's lifetime, so this reference cannot outlive its target.
    var appearance: AppearanceSettings? {
        didSet {
            if let appearance {
                appearance.themeStore = themeStore
                setupAppearanceSubscriptions(appearance)
            }
        }
    }
    /// Subscription to appearance.$schemeID changes for pushing COLORFGBG updates to running tmux servers.
    private var appearanceSubscription: AnyCancellable?
    /// Subscription to themeStore.$userThemes changes for reconciling the active scheme.
    private var themeStoreSubscription: AnyCancellable?

    @Published var repos: [Repo] = []
    @Published var worktrees: [UUID: [Worktree]] = [:]
    @Published var terminals: [UUID: [Terminal]] = [:]
    @Published var notes: [UUID: [Note]] = [:]
    @Published var focusedTabCloseContext: TabCloseContext?
    /// Unread notification summaries keyed by worktree ID. The cmd-K jump
    /// menu sorts by `mostRecentAt`; the sidebar consumes `.type` for the
    /// severity dot. Worktrees the user is currently viewing are excluded
    /// from this dictionary because `refreshNotifications` auto-marks them
    /// read on every poll.
    @Published var unreadByWorktree: [UUID: UnreadSummary] = [:]
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
                // Feed the jump menu's Recent section. Insertion-order LRU,
                // most-recent-first; capped at 32 to bound memory. Only the
                // most-recently-added worktree ID is recorded per selection
                // event — multi-select doesn't make sense for "the worktree
                // I just looked at". Intentionally not gated on
                // `isNavigating`: cmd+[ / cmd+] are real visits and should
                // reorder the jump menu Recents (Slack-style).
                if let id = selectionOrder.last {
                    recentWorktreeIDs.removeAll { $0 == id }
                    recentWorktreeIDs.insert(id, at: 0)
                    if recentWorktreeIDs.count > Self.recentWorktreeCap {
                        recentWorktreeIDs.removeLast(recentWorktreeIDs.count - Self.recentWorktreeCap)
                    }
                }
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

    /// Whether there are more archived worktrees to load beyond what's in `archivedWorktrees`.
    @Published var archivedWorktreesHasMore: [UUID: Bool] = [:]

    /// Set briefly when a deep link lands on an archived worktree. The
    /// ArchivedWorktreesView observes this and scrolls/flashes the matching
    /// row, then clears the value after the flash animation completes.
    @Published var highlightedArchivedWorktreeID: UUID?

    /// Set briefly when external navigation (notification click, deep link,
    /// jump menu) lands on an active worktree. `SidebarView` observes this
    /// to scroll the worktree row into view, then clears the value.
    @Published var pendingScrollToWorktreeID: UUID?

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

    /// Companion to `pendingDeepLinkID`: buffers the originating terminal so
    /// cold-start clicks land on the right tab after the drain. Drained
    /// alongside `pendingDeepLinkID` at the end of
    /// `connectAndLoadInitialState()`. Internal-only — never written from
    /// outside the AppState extension that consumes it.
    var pendingDeepLinkTerminalID: UUID?

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
        didSet { userDefaults.set(Double(dockRatio), forKey: Self.dockRatioKey) }
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
    @Published var worktreeTabOrders: [UUID: [UUID]] = [:]
    @Published var draggingTabID: UUID? = nil
    @Published var repoFilter: UUID? = nil
    @Published var pendingWorktreeIDs: Set<UUID> = []
    /// Worktree IDs optimistically removed by an archive that has not yet been
    /// confirmed by daemon data. `refreshWorktrees` filters these out so a
    /// `listWorktrees` poll issued before the daemon flipped the status cannot
    /// resurrect the row. Value is the time the tombstone was created, used for
    /// TTL-based eviction when an archive fails or stalls.
    var recentlyArchivedWorktreeIDs: [UUID: Date] = [:]
    @Published var suspendingTerminalIDs: Set<UUID> = []
    /// Closures registered by live TerminalPanelView instances to capture a screenshot.
    /// Keyed by terminal UUID. Populated in makeNSView, cleared on view disappear.
    var snapshotProviders: [UUID: () -> NSImage?] = [:]
    /// Weak terminal views keyed by terminal UUID, used to restore AppKit first
    /// responder after worktree navigation.
    var terminalFocusTargets: [UUID: TerminalFocusTarget] = [:]
    /// Tab-close ownership keyed by terminal UUID for views that belong to a
    /// visible tab, used to resolve the currently focused closable tab.
    var terminalTabCloseContexts: [UUID: TabCloseContext] = [:]
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
    @Published var modelProfiles: [ModelProfileWithUsage] = []
    @Published var defaultProfileID: UUID? = nil
    @Published var primaryAgentPreference: PrimaryAgentPreference = .defaultValue
    /// Terminals where the user has dismissed the proxy-unreachable banner.
    /// Cleared on app relaunch (in-memory only — banners are advisory).
    @Published var dismissedProxyWarnings: Set<UUID> = []
    @Published var historyActiveWorktrees: Set<UUID> = []
    @Published var historyLoadStates: [UUID: HistoryLoadState] = [:]
    @Published var selectedSessionIDs: [UUID: String] = [:]       // worktreeID → sessionId
    @Published var sessionTranscripts: [String: [TranscriptItem]] = [:]  // sessionId → items
    @Published var sessionTranscriptLoading: Set<String> = []

    /// Worktree IDs whose view trees we keep alive past their selection,
    /// most-recent-first. Cap: keepAliveLimit. Older worktrees get evicted
    /// (their SingleWorktreeView unmounts) when the cap is exceeded.
    @Published private(set) var recentlyVisitedWorktreeIDs: [UUID] = []

    /// LRU of recently-selected worktrees consumed by the cmd-K jump menu.
    /// Distinct from `recentlyVisitedWorktreeIDs` (which has a much smaller
    /// cap and drives the SingleWorktreeView keep-alive cache). In-memory
    /// only — resets on app relaunch, matching Slack's "Recent" semantics.
    @Published private(set) var recentWorktreeIDs: [UUID] = []

    private static let recentWorktreeCap = 32

    private let keepAliveLimit = 8

    /// Move `id` to the front of recentlyVisitedWorktreeIDs, evicting the
    /// oldest entries if we exceed keepAliveLimit. Idempotent — calling
    /// repeatedly with the same id only updates ordering.
    func touchVisitedWorktree(_ id: UUID) {
        recentlyVisitedWorktreeIDs.removeAll { $0 == id }
        recentlyVisitedWorktreeIDs.insert(id, at: 0)
        if recentlyVisitedWorktreeIDs.count > keepAliveLimit {
            recentlyVisitedWorktreeIDs.removeLast(
                recentlyVisitedWorktreeIDs.count - keepAliveLimit
            )
        }
    }

    /// Insertion/access order for `sessionTranscripts`. The most recently
    /// touched sessionID is at the END. Evict from the FRONT when the cap
    /// is exceeded.
    private var sessionTranscriptOrder: [String] = []
    private let sessionTranscriptCap = 50

    /// Touch a sessionID — moves it to most-recently-used, evicts the LRU
    /// entry if we're over the cap. Call this whenever an entry in
    /// sessionTranscripts is added or updated.
    func touchSessionTranscript(_ sessionID: String) {
        if let existingIdx = sessionTranscriptOrder.firstIndex(of: sessionID) {
            sessionTranscriptOrder.remove(at: existingIdx)
        }
        sessionTranscriptOrder.append(sessionID)
        while sessionTranscriptOrder.count > sessionTranscriptCap {
            let evict = sessionTranscriptOrder.removeFirst()
            sessionTranscripts.removeValue(forKey: evict)
        }
    }

    /// Selected archived worktree per repo (left rail of the archived view's nested master-detail).
    @Published var selectedArchivedWorktreeIDs: [UUID: UUID] = [:]

    /// Worktrees the user just revived from the archived view. Keeps the row
    /// visible with a status indicator until the user navigates away from the
    /// archived section. Cleared by `AppState+Navigation` when the active
    /// sidebar selection moves elsewhere.
    @Published var revivingArchived: [UUID: ReviveState] = [:]

    /// Terminal IDs currently being recreated — prevents duplicate RPC calls.
    var recreatingTerminalIDs: Set<UUID> = []

    // Alert state for user feedback
    @Published var alertMessage: String? = nil
    @Published var alertIsError: Bool = false

    let themeStore = ThemeStore()

    let daemonClient = DaemonClient()
    let tmuxBridge = TmuxBridge()
    lazy var cliInstallerCoordinator = CLIInstallerCoordinator(daemonClient: daemonClient, userDefaults: userDefaults)
    lazy var legacyHooksCoordinator = LegacyHooksCoordinator(daemonClient: daemonClient, userDefaults: userDefaults)
    private var pollTimer: Timer?
    private var pollCycle = 0
    private var subscriptionTask: Task<Void, Never>?
    let notificationSoundPlayer = NotificationSoundPlayer()
    let macNotificationManager = MacNotificationManager()

    private static let layoutsKey = "com.tbd.app.layouts"
    private static let dockRatioKey = "com.tbd.app.dockRatio"

    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var focusObservers: [NSObjectProtocol] = []

    /// UserDefaults domain this AppState reads instance-level preferences from.
    /// Production uses `.standard`; tests inject a per-suite `UserDefaults(suiteName:)`
    /// so they never clobber the developer's running app preferences.
    let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        restoreLayouts()
        if let saved = userDefaults.object(forKey: Self.dockRatioKey) as? Double {
            dockRatio = max(0.1, min(0.6, CGFloat(saved)))
        }
        startMemoryPressureMonitor()
        registerFocusObservers()
        // Give the notification manager a back-reference so banner clicks
        // can call navigateToWorktree. All stored properties are now
        // initialized, so `self` is fully usable here.
        macNotificationManager.configure(appState: self)
        themeStore.reloadFromDisk()
        themeStore.startWatching()
        // Under `swift test`, the per-test `AppState()` instances would each
        // spawn a subscription Task that blocks indefinitely in `recv()` on
        // the daemon socket. With enough tests the Swift cooperative thread
        // pool saturates and the test runner deadlocks. Production is
        // unbundled (no .xctest in args), so this guard is a no-op there.
        if !Self.isRunningUnderTests {
            Task {
                await connectAndLoadInitialState()
                startPolling()
            }
        }
    }

    /// True when this process is a SwiftPM / XCTest test harness. Detected by
    /// looking for a `.xctest` bundle path in the process arguments, which
    /// both XCTest and Swift Testing (via `swiftpm-testing-helper`) pass.
    private static let isRunningUnderTests: Bool = {
        ProcessInfo.processInfo.arguments.contains { $0.contains(".xctest") }
    }()

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
            // Dismiss banners for any worktree that is already visible so
            // stale Notification Center entries are cleared when TBD comes
            // to the foreground. The observer runs on .main, but the closure
            // is Sendable from Swift 6's view — hop via assumeIsolated.
            MainActor.assumeIsolated {
                self.macNotificationManager.dismissDelivered(worktreeIDs: self.visibleWorktreeIDs)
            }
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

    // MARK: - Appearance Subscriptions

    /// Subscribe to appearance setting changes and push updates to running tmux servers.
    /// Called when `appearance` is set via didSet.
    @MainActor
    private func setupAppearanceSubscriptions(_ appearance: AppearanceSettings) {
        // Subscribe to schemeID changes to push COLORFGBG updates to all running tmux servers.
        // When the user changes the color scheme, this notifies all shells so tools like vim,
        // less, fzf can auto-adjust to the new scheme.
        // Debounce rapid changes (e.g., scrubbing through the scheme picker) to coalesce
        // multiple RPCs into a single request. The 200ms window is long enough to capture
        // rapid picker changes but short enough to feel responsive.
        appearanceSubscription = appearance.$schemeID
            // `@Published` delivers the current value at subscription time. Without
            // `dropFirst()`, broadcastAppearanceColorFgBg runs on app launch before
            // the daemon connection is even established — the RPC fails, the error
            // gets logged and swallowed. Drop that subscriber-time emission so we
            // only react to actual user-driven scheme changes.
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.broadcastAppearanceColorFgBg(appearance)
            }

        // When the theme store reloads (external file add/delete/edit), reconcile
        // the active schemeID so a deleted theme falls back to the default rather
        // than leaving the UI pointing at an unknown id.
        themeStoreSubscription = themeStore.$userThemes
            .dropFirst()  // skip subscriber-time emission, match appearanceSubscription pattern
            .sink { [weak appearance] _ in
                appearance?.reconcileWithStore()
            }
    }

    /// Compute the new COLORFGBG value and push it to all running tmux servers.
    @MainActor
    private func broadcastAppearanceColorFgBg(_ appearance: AppearanceSettings) {
        let newValue = appearance.currentColorFgBg
        Task {
            do {
                try await daemonClient.updateAppearanceColorFgBg(value: newValue)
            } catch {
                logger.error("Failed to broadcast COLORFGBG update: \(error, privacy: .public)")
                // Fire-and-forget: don't block on RPC failure
            }
        }
    }

    // MARK: - Layout Persistence

    private func persistLayouts() {
        guard let data = try? JSONEncoder().encode(layouts) else { return }
        userDefaults.set(data, forKey: Self.layoutsKey)
    }

    private func restoreLayouts() {
        guard let data = userDefaults.data(forKey: Self.layoutsKey),
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
        case .modelProfileUsageUpdated(let usage):
            applyModelProfileUsageDelta(usage)
        case .modelProfilesChanged:
            Task { [weak self] in await self?.loadModelProfiles() }
        case .terminalSessionUpdated(let d):
            applyTerminalSessionDelta(d)
        case .worktreeMoved(let d):
            applyWorktreeMovedDelta(d)
        case .worktreeArchived(let d):
            applyWorktreeArchivedDelta(d)
        case .worktreeRevived(let d):
            recentlyArchivedWorktreeIDs.removeValue(forKey: d.worktreeID)
            Task { [weak self] in await self?.refreshWorktrees() }
        default:
            break
        }
    }

    /// Apply a worktree move (new parent + sortOrder) directly to the in-memory
    /// model so the sidebar reflects the change without waiting for the next
    /// `worktree.list` poll. Searches all repos for the worktree — moves
    /// across repos aren't supported by the daemon today, so we mutate in
    /// place once we find it.
    private func applyWorktreeMovedDelta(_ delta: WorktreeMovedDelta) {
        for (repoID, rows) in worktrees {
            if let idx = rows.firstIndex(where: { $0.id == delta.worktreeID }) {
                var updated = rows
                updated[idx].parentWorktreeID = delta.newParentID
                updated[idx].sortOrder = delta.newSortOrder
                worktrees[repoID] = updated
                break
            }
        }
    }

    /// Daemon confirmed a worktree was archived (possibly from the CLI or another
    /// client). Tombstone it and drop the row so it cannot be resurrected by a
    /// poll snapshot that predates the archive.
    private func applyWorktreeArchivedDelta(_ delta: WorktreeIDDelta) {
        removeArchivedWorktreeFromState(id: delta.worktreeID)
    }

    /// Apply a Claude session rollover (post-`/clear` / `/compact` / startup)
    /// directly to the in-memory Terminal so LiveTranscriptPaneView re-targets
    /// without waiting for the next 2s `terminal.list` poll. Silently ignores
    /// terminals we don't know about — the next refresh will reconcile.
    private func applyTerminalSessionDelta(_ delta: TerminalSessionDelta) {
        guard let idx = terminals[delta.worktreeID]?.firstIndex(where: { $0.id == delta.terminalID }) else {
            return
        }
        terminals[delta.worktreeID]?[idx].claudeSessionID = delta.sessionID
        // Mirror TerminalStore.updateSession's preserve-on-nil: a delta with
        // nil transcriptPath means the SessionStart payload didn't carry a
        // path even though sessionID rolled. Keep the previous value so the
        // in-memory model doesn't drift from the DB.
        if let tp = delta.transcriptPath {
            terminals[delta.worktreeID]?[idx].transcriptPath = tp
        }
    }

    /// Update the in-place usage entry for a single profile. If no match,
    /// silently ignore — the next full refresh will pick it up.
    private func applyModelProfileUsageDelta(_ usage: ModelProfileUsage) {
        guard let idx = modelProfiles.firstIndex(where: { $0.profile.id == usage.profileID }) else {
            return
        }
        let existing = modelProfiles[idx]
        modelProfiles[idx] = ModelProfileWithUsage(profile: existing.profile, usage: usage)
    }

    private func handleNotificationDelta(_ notification: NotificationDelta) {
        let visible = visibleWorktreeIDs
        guard !visible.contains(notification.worktreeID) else { return }

        // Update local unread summary state. The delta doesn't carry a
        // timestamp so we use "now" — close enough for the jump menu's
        // recency-based sort. Merge with any existing summary so a lower-
        // severity arrival (e.g. responseComplete) doesn't downgrade a
        // higher-severity unread (e.g. error) until the next DB poll.
        let incoming = UnreadSummary(type: notification.type, mostRecentAt: Date())
        if let existing = unreadByWorktree[notification.worktreeID] {
            let winnerType = incoming.type.severity > existing.type.severity
                ? incoming.type : existing.type
            unreadByWorktree[notification.worktreeID] = UnreadSummary(
                type: winnerType,
                mostRecentAt: incoming.mostRecentAt
            )
        } else {
            unreadByWorktree[notification.worktreeID] = incoming
        }

        // Fire sound + macOS notification
        notificationSoundPlayer.playIfEnabled()
        macNotificationManager.postIfEnabled(
            worktreeID: notification.worktreeID,
            message: notification.message,
            worktrees: allWorktrees,
            terminalID: notification.terminalID
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
                        if didConnect { self.pushClaudeSpawnPreferences() }
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
            await loadModelProfiles()
            startSubscription()
            await refreshPRStatuses()
            let suspendEnabled = AppState.autoSuspendClaudeEnabled(defaults: userDefaults)
            Task { [selectedWorktreeIDs] in
                try? await daemonClient.worktreeSelectionChanged(
                    selectedWorktreeIDs: selectedWorktreeIDs,
                    suspendEnabled: suspendEnabled
                )
            }
            pushClaudeSpawnPreferences()
        } else {
            logger.warning("Could not connect to daemon — is tbdd running?")
        }
        isInitialStateLoaded = true
        if let pendingID = pendingDeepLinkID {
            let pendingTerminalID = pendingDeepLinkTerminalID
            pendingDeepLinkID = nil
            pendingDeepLinkTerminalID = nil
            navigateToWorktree(pendingID, terminalID: pendingTerminalID)
        }
        if didConnect {
            Task { [weak self] in
                guard let self else { return }
                await self.cliInstallerCoordinator.checkOnLaunch()
            }
            Task { [weak self] in
                guard let self else { return }
                await self.legacyHooksCoordinator.checkOnLaunch()
            }
        }
    }

    /// Menu entry point — install or refresh the `tbd` CLI symlink.
    func installCLITool() async {
        await cliInstallerCoordinator.runFromMenu()
    }

    /// Menu entry point — review and (optionally) remove TBD's legacy
    /// hook entries from the user's `~/.claude/settings.json`.
    func migrateClaudeHooks() async {
        await legacyHooksCoordinator.runFromMenu()
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
            // Single RPC — fetch all worktrees (including archived)
            let allWts = try await daemonClient.listWorktrees(repoID: repoID)
            // Drop tombstones the daemon has confirmed (or that outlived the TTL) so a
            // stale poll predating an archive cannot resurrect the row.
            // Reconcile only on the unscoped path: a scoped allWts omits other repos'
            // worktrees, which would look absent and evict their tombstones prematurely.
            if repoID == nil {
                recentlyArchivedWorktreeIDs = AppState.reconcileTombstones(
                    recentlyArchivedWorktreeIDs,
                    daemonWorktrees: allWts,
                    now: Date()
                )
            }
            let fetched = AppState.visibleWorktrees(
                from: allWts,
                tombstones: Set(recentlyArchivedWorktreeIDs.keys)
            )

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
        let alreadyLoadedOrder = worktreeTabOrders[worktreeID] != nil
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
        applyStoredOrder(worktreeID: worktreeID)
        if !alreadyLoadedOrder {
            Task { await loadTabStates(worktreeID: worktreeID) }
        }
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
            currentTabs.append(Tab(id: note.id, content: .note(noteID: note.id), label: nil))
        }

        tabs[worktreeID] = currentTabs
        applyStoredOrder(worktreeID: worktreeID)
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
            if filtered != unreadByWorktree {
                unreadByWorktree = filtered
            }
        } catch {
            logger.error("Failed to list notifications: \(error)")
            handleConnectionError(error)
        }
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
        userDefaults.bool(forKey: Self.terminalAutoResizeKey)
    }

    /// UserDefaults key mirroring the `@AppStorage("autoSuspendClaude")`
    /// toggle in the Settings → Experimental section. Read from non-View
    /// contexts (e.g. the daemon-reconnect path) to avoid sending
    /// `suspendEnabled=true` when the user has not opted in.
    static let autoSuspendClaudeKey = "autoSuspendClaude"

    /// Whether auto-suspend is enabled. Fails closed: defaults to false when
    /// the user has never touched the toggle, matching the `@AppStorage`
    /// defaults. Tests pass a private `UserDefaults(suiteName:)` so they
    /// never mutate the developer's live app preferences.
    static func autoSuspendClaudeEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: autoSuspendClaudeKey) as? Bool ?? false
    }

    /// UserDefaults key for a Claude spawn-env setting, by registry ID.
    nonisolated static func claudeEnvKey(_ settingID: String) -> String {
        "claudeEnvSetting.\(settingID)"
    }

    /// Build the overrides map from UserDefaults: a setting is included only
    /// when the user has changed it from its registry default. Settings left
    /// at default are omitted so the daemon falls back to registry defaults.
    nonisolated static func claudeEnvOverrides(defaults: UserDefaults = .standard) -> [String: ClaudeEnvValue] {
        var overrides: [String: ClaudeEnvValue] = [:]
        for setting in ClaudeEnvRegistry.all {
            let key = claudeEnvKey(setting.id)
            switch setting.kind {
            case .toggle(let def, _):
                if let stored = defaults.object(forKey: key) as? Bool, stored != def {
                    overrides[setting.id] = .bool(stored)
                }
            }
        }
        return overrides
    }

    /// Push the current Claude spawn-env setting overrides to the daemon.
    /// Safe to call repeatedly — the daemon persists the latest value.
    func pushClaudeSpawnPreferences() {
        let overrides = Self.claudeEnvOverrides(defaults: userDefaults)
        Task { [daemonClient] in
            try? await daemonClient.setClaudeSpawnPreferences(
                ClaudeSpawnPreferences(settingOverrides: overrides))
        }
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
        // Use the user's current font so initial pane dimensions match what
        // the freshly-spawned `TBDTerminalView` will render with. Falls back
        // to the SwiftTerm default if `appearance` hasn't been wired yet
        // (only possible during pre-`onAppear` startup ordering).
        let font = appearance?.font ?? TBDTerminalView.defaultMonospaceFont
        let cell = TBDTerminalView.cellDimensions(for: font)
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

}
