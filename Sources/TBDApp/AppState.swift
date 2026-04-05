import Foundation
import SwiftUI
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState")

@MainActor
final class AppState: ObservableObject {
    @Published var repos: [Repo] = []
    @Published var worktrees: [UUID: [Worktree]] = [:]
    @Published var terminals: [UUID: [Terminal]] = [:]
    @Published var notes: [UUID: [Note]] = [:]
    @Published var notifications: [UUID: NotificationType?] = [:]
    @Published var selectedWorktreeIDs: Set<UUID> = [] {
        didSet {
            // Remove deselected items from order
            selectionOrder.removeAll { !selectedWorktreeIDs.contains($0) }
            // Append newly selected items (maintains insertion order for cmd+click)
            for id in selectedWorktreeIDs where !selectionOrder.contains(id) {
                selectionOrder.append(id)
            }
            // Clear repo selection when a worktree is selected
            if !selectedWorktreeIDs.isEmpty {
                selectedRepoID = nil
            }
        }
    }
    /// Tracks the order of selected worktrees for split view rendering (cmd+click order).
    @Published var selectionOrder: [UUID] = []
    /// Selected repo ID — set when a repo header is clicked, shows archived worktrees in content pane.
    @Published var selectedRepoID: UUID? = nil
    /// Archived worktrees keyed by repo ID, fetched on demand.
    @Published var archivedWorktrees: [UUID: [Worktree]] = [:]

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
    @Published var isConnected: Bool = false
    @Published var layouts: [UUID: LayoutNode] = [:] {
        didSet { persistLayouts() }
    }
    @Published var tabs: [UUID: [Tab]] = [:]
    @Published var activeTabIndices: [UUID: Int] = [:]
    @Published var repoFilter: UUID? = nil
    @Published var pendingWorktreeIDs: Set<UUID> = []
    @Published var editingWorktreeID: UUID? = nil
    @Published var isRenamingWorktree = false
    @Published var prStatuses: [UUID: PRStatus] = [:]

    /// Conductor for each repo (wildcard conductors expanded across all repos).
    @Published var conductorsByRepo: [UUID: Conductor] = [:]
    /// The conductor's terminal record, keyed by repo ID.
    @Published var conductorTerminalsByRepo: [UUID: Terminal] = [:]
    /// Current navigation suggestion from any conductor.
    @Published var conductorSuggestion: ConductorSuggestion? = nil
    /// Whether the conductor overlay is visible.
    @Published var showConductor: Bool = false
    /// Conductor overlay height — persisted.
    @Published var conductorHeight: CGFloat = 300 {
        didSet { UserDefaults.standard.set(Double(conductorHeight), forKey: Self.conductorHeightKey) }
    }
    /// Remembers selected tab index per worktree so switching back restores the tab.
    @Published var selectedTabIndex: [UUID: Int] = [:]

    /// Terminal IDs currently being recreated — prevents duplicate RPC calls.
    var recreatingTerminalIDs: Set<UUID> = []

    // Alert state for user feedback
    @Published var alertMessage: String? = nil
    @Published var alertIsError: Bool = false

    let daemonClient = DaemonClient()
    let tmuxBridge = TmuxBridge()
    private var pollTimer: Timer?
    private var pollCycle = 0

    private static let layoutsKey = "com.tbd.app.layouts"
    private static let dockRatioKey = "com.tbd.app.dockRatio"
    private static let conductorHeightKey = "com.tbd.app.conductorHeight"

    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init() {
        restoreLayouts()
        if let saved = UserDefaults.standard.object(forKey: Self.dockRatioKey) as? Double {
            dockRatio = max(0.1, min(0.6, CGFloat(saved)))
        }
        if let savedHeight = UserDefaults.standard.object(forKey: Self.conductorHeightKey) as? Double {
            conductorHeight = max(100, min(800, CGFloat(savedHeight)))
        }
        startMemoryPressureMonitor()
        Task {
            await connectAndLoadInitialState()
            startPolling()
        }
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
            await refreshPRStatuses()
            Task {
                try? await daemonClient.worktreeSelectionChanged(
                    selectedWorktreeIDs: selectedWorktreeIDs
                )
            }
        } else {
            logger.warning("Could not connect to daemon — is tbdd running?")
        }
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
                        // Find the conductor's terminal in the terminals dict
                        if let termID = conductor.terminalID,
                           let wtID = conductor.worktreeID,
                           let term = terminals[wtID]?.first(where: { $0.id == termID }) {
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
