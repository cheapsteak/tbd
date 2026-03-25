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
    @Published var notifications: [UUID: NotificationType?] = [:]
    @Published var selectedWorktreeIDs: Set<UUID> = []
    @Published var isConnected: Bool = false
    @Published var layouts: [UUID: LayoutNode] = [:] {
        didSet { persistLayouts() }
    }
    @Published var tabs: [UUID: [Tab]] = [:]
    @Published var activeTabIndices: [UUID: Int] = [:]
    @Published var repoFilter: UUID? = nil
    @Published var pendingWorktreeIDs: Set<UUID> = []
    @Published var editingWorktreeID: UUID? = nil
    @Published var prStatuses: [UUID: PRStatus] = [:]
    /// Remembers selected tab index per worktree so switching back restores the tab.
    @Published var selectedTabIndex: [UUID: Int] = [:]

    // Alert state for user feedback
    @Published var alertMessage: String? = nil
    @Published var alertIsError: Bool = false

    let daemonClient = DaemonClient()
    let tmuxBridge = TmuxBridge()
    private var pollTimer: Timer?
    private var pollCycle = 0

    private static let layoutsKey = "com.tbd.app.layouts"

    init() {
        restoreLayouts()
        Task {
            await connectAndLoadInitialState()
            startPolling()
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
            // Fetch active, main, and creating worktrees separately and combine
            let activeWts = try await daemonClient.listWorktrees(repoID: repoID, status: .active)
            let mainWts = try await daemonClient.listWorktrees(repoID: repoID, status: .main)
            let creatingWts = try await daemonClient.listWorktrees(repoID: repoID, status: .creating)
            let fetched = mainWts + activeWts + creatingWts
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
            // Refresh terminals for visible worktrees
            let allWorktrees: [Worktree]
            if let repoID {
                allWorktrees = worktrees[repoID] ?? []
            } else {
                allWorktrees = Array(worktrees.values.joined())
            }
            for wt in allWorktrees {
                await refreshTerminals(worktreeID: wt.id)
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
    func refreshNotifications() async {
        do {
            let fetched = try await daemonClient.listNotifications()
            if fetched != notifications.compactMapValues({ $0 }) {
                var updated: [UUID: NotificationType?] = [:]
                for (id, type) in fetched {
                    updated[id] = type
                }
                notifications = updated
            }
        } catch {
            logger.error("Failed to list notifications: \(error)")
            handleConnectionError(error)
        }
    }
}
