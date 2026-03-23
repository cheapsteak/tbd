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
    @Published var mergeStatus: [UUID: WorktreeMergeStatusResult] = [:]
    @Published var selectedWorktreeIDs: Set<UUID> = []
    @Published var isConnected: Bool = false
    @Published var layouts: [UUID: LayoutNode] = [:]
    @Published var repoFilter: UUID? = nil
    @Published var pendingWorktreeIDs: Set<UUID> = []
    @Published var editingWorktreeID: UUID? = nil

    // Alert state for user feedback
    @Published var alertMessage: String? = nil
    @Published var alertIsError: Bool = false

    let daemonClient = DaemonClient()
    let tmuxBridge = TmuxBridge()
    private var pollTimer: Timer?

    init() {
        Task {
            await connectAndLoadInitialState()
            startPolling()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Poll daemon for state changes every 2 seconds.
    /// Merge status for selected worktree checked every 5th cycle (~10s).
    private var pollCycle = 0
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

                // Check merge status for selected worktree every ~10s
                self.pollCycle += 1
                if self.pollCycle % 5 == 0, let selectedID = self.selectedWorktreeIDs.first {
                    await self.refreshMergeStatus(worktreeID: selectedID)
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

    /// Refresh all state from the daemon.
    func refreshAll() async {
        await refreshRepos()
        await refreshWorktrees()
    }

    /// Refresh the repo list. Only updates if data changed.
    func refreshRepos() async {
        do {
            let fetchedRepos = try await daemonClient.listRepos()
            if fetchedRepos.map(\.id) != repos.map(\.id) {
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
            // Fetch active and main worktrees separately and combine
            let activeWts = try await daemonClient.listWorktrees(repoID: repoID, status: .active)
            let mainWts = try await daemonClient.listWorktrees(repoID: repoID, status: .main)
            let fetched = mainWts + activeWts
            if let repoID {
                let existing = worktrees[repoID] ?? []
                if fetched.map(\.id) != existing.map(\.id) {
                    worktrees[repoID] = fetched
                }
            } else {
                var grouped: [UUID: [Worktree]] = [:]
                for wt in fetched {
                    grouped[wt.repoID, default: []].append(wt)
                }
                // Preserve pending placeholders that aren't in the server response yet
                for (repoID, wts) in worktrees {
                    for wt in wts where pendingWorktreeIDs.contains(wt.id) {
                        if !grouped[repoID, default: []].contains(where: { $0.id == wt.id }) {
                            grouped[repoID, default: []].append(wt)
                        }
                    }
                }
                // Only update if changed
                let oldIDs = Set(worktrees.values.flatMap { $0.map(\.id) })
                let newIDs = Set(grouped.values.flatMap { $0.map(\.id) })
                if oldIDs != newIDs {
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
            if fetched.map(\.id) != existing.map(\.id) {
                terminals[worktreeID] = fetched
            }
        } catch {
            logger.error("Failed to list terminals for worktree \(worktreeID): \(error)")
            handleConnectionError(error)
        }
    }

    // MARK: - Repo Actions

    /// Add a repository by path.
    func addRepo(path: String) async {
        do {
            let repo = try await daemonClient.addRepo(path: path)
            repos.append(repo)
            isConnected = true
        } catch {
            logger.error("Failed to add repo: \(error)")
            handleConnectionError(error)
        }
    }

    /// Remove a repository.
    func removeRepo(repoID: UUID, force: Bool = false) async {
        do {
            try await daemonClient.removeRepo(repoID: repoID, force: force)
            repos.removeAll { $0.id == repoID }
            worktrees.removeValue(forKey: repoID)
        } catch {
            logger.error("Failed to remove repo: \(error)")
            handleConnectionError(error)
        }
    }

    // MARK: - Worktree Actions

    /// Create a new worktree in a repo.
    /// Inserts a placeholder immediately and creates the real worktree in the background.
    func createWorktree(repoID: UUID) {
        let name = NameGenerator.generate()
        let placeholderID = UUID()
        let placeholder = Worktree(
            id: placeholderID, repoID: repoID, name: name, displayName: name,
            branch: "tbd/\(name)", path: "", status: .active, tmuxServer: ""
        )
        worktrees[repoID, default: []].append(placeholder)
        selectedWorktreeIDs = [placeholderID]
        pendingWorktreeIDs.insert(placeholderID)
        editingWorktreeID = placeholderID

        Task {
            do {
                let wt = try await daemonClient.createWorktree(repoID: repoID, name: name)
                // Replace placeholder with real worktree
                if let idx = worktrees[repoID]?.firstIndex(where: { $0.id == placeholderID }) {
                    // Preserve any display name the user set while waiting
                    let userDisplayName = worktrees[repoID]?[idx].displayName
                    worktrees[repoID]?[idx] = wt
                    if let userDisplayName, userDisplayName != name {
                        worktrees[repoID]?[idx].displayName = userDisplayName
                        // Persist the rename on the server
                        try? await daemonClient.renameWorktree(id: wt.id, displayName: userDisplayName)
                    }
                }
                pendingWorktreeIDs.remove(placeholderID)
                if selectedWorktreeIDs.contains(placeholderID) {
                    selectedWorktreeIDs.remove(placeholderID)
                    selectedWorktreeIDs.insert(wt.id)
                }
                await refreshTerminals(worktreeID: wt.id)
            } catch {
                logger.error("Failed to create worktree: \(error)")
                // Remove placeholder on failure
                worktrees[repoID]?.removeAll { $0.id == placeholderID }
                pendingWorktreeIDs.remove(placeholderID)
                selectedWorktreeIDs.remove(placeholderID)
                handleConnectionError(error)
            }
        }
    }

    /// Archive a worktree.
    func archiveWorktree(id: UUID, force: Bool = false) async {
        do {
            try await daemonClient.archiveWorktree(id: id, force: force)
            for repoID in worktrees.keys {
                worktrees[repoID]?.removeAll { $0.id == id }
            }
            selectedWorktreeIDs.remove(id)
            terminals.removeValue(forKey: id)
        } catch {
            logger.error("Failed to archive worktree: \(error)")
            handleConnectionError(error)
        }
    }

    /// Merge a worktree branch into main via rebase.
    func mergeWorktree(id: UUID, archiveAfter: Bool = false) async {
        // Find the worktree name for the alert message
        let worktreeName = worktrees.values.flatMap { $0 }.first { $0.id == id }?.displayName ?? "worktree"
        do {
            try await daemonClient.mergeWorktree(id: id, archiveAfter: archiveAfter)
            if archiveAfter {
                for repoID in worktrees.keys {
                    worktrees[repoID]?.removeAll { $0.id == id }
                }
                selectedWorktreeIDs.remove(id)
                terminals.removeValue(forKey: id)
                showAlert("Merged and archived \(worktreeName)")
            } else {
                showAlert("Merged \(worktreeName) to main")
            }
        } catch {
            logger.error("Failed to merge worktree: \(error)")
            showAlert("Merge failed: \(error)", isError: true)
        }
    }

    func showAlert(_ message: String, isError: Bool = false) {
        alertMessage = message
        alertIsError = isError
    }

    /// Revive an archived worktree.
    func reviveWorktree(id: UUID) async {
        do {
            try await daemonClient.reviveWorktree(id: id)
            await refreshWorktrees()
        } catch {
            logger.error("Failed to revive worktree: \(error)")
            handleConnectionError(error)
        }
    }

    /// Rename a worktree.
    func renameWorktree(id: UUID, displayName: String) async {
        // For pending worktrees, just update locally — the name will be applied when creation finishes
        if pendingWorktreeIDs.contains(id) {
            for repoID in worktrees.keys {
                if let idx = worktrees[repoID]?.firstIndex(where: { $0.id == id }) {
                    worktrees[repoID]?[idx].displayName = displayName
                }
            }
            return
        }
        do {
            try await daemonClient.renameWorktree(id: id, displayName: displayName)
            for repoID in worktrees.keys {
                if let idx = worktrees[repoID]?.firstIndex(where: { $0.id == id }) {
                    worktrees[repoID]?[idx].displayName = displayName
                }
            }
        } catch {
            logger.error("Failed to rename worktree: \(error)")
            handleConnectionError(error)
        }
    }

    // MARK: - Merge Status

    /// Refresh the merge status for a specific worktree (called on-demand, not during polling).
    func refreshMergeStatus(worktreeID: UUID) async {
        do {
            let status = try await daemonClient.checkMergeability(worktreeID: worktreeID)
            mergeStatus[worktreeID] = status
        } catch {
            logger.error("Failed to check merge status for \(worktreeID): \(error)")
            handleConnectionError(error)
        }
    }

    // MARK: - Terminal Actions

    /// Create a terminal in a worktree.
    func createTerminal(worktreeID: UUID, cmd: String? = nil) async {
        do {
            let terminal = try await daemonClient.createTerminal(worktreeID: worktreeID, cmd: cmd)
            terminals[worktreeID, default: []].append(terminal)
        } catch {
            logger.error("Failed to create terminal: \(error)")
            handleConnectionError(error)
        }
    }

    /// Send text to a terminal.
    func sendToTerminal(terminalID: UUID, text: String) async {
        do {
            try await daemonClient.sendToTerminal(terminalID: terminalID, text: text)
        } catch {
            logger.error("Failed to send to terminal: \(error)")
            handleConnectionError(error)
        }
    }

    // MARK: - Notification Actions

    /// Send a notification.
    func notify(worktreeID: UUID?, type: NotificationType, message: String? = nil) async {
        do {
            try await daemonClient.notify(worktreeID: worktreeID, type: type, message: message)
        } catch {
            logger.error("Failed to send notification: \(error)")
            handleConnectionError(error)
        }
    }

    // MARK: - Notification Actions

    /// Mark all notifications for a worktree as read.
    func markNotificationsRead(worktreeID: UUID) async {
        do {
            try await daemonClient.markNotificationsRead(worktreeID: worktreeID)
            notifications[worktreeID] = nil
        } catch {
            // Not critical — just clear locally
            logger.warning("Failed to mark notifications read for \(worktreeID): \(error)")
            notifications[worktreeID] = nil
        }
    }

    // MARK: - Daemon Status

    /// Get daemon status info.
    func fetchDaemonStatus() async -> DaemonStatusResult? {
        do {
            let status = try await daemonClient.daemonStatus()
            isConnected = true
            return status
        } catch {
            logger.error("Failed to get daemon status: \(error)")
            handleConnectionError(error)
            return nil
        }
    }

    // MARK: - Keyboard Shortcut Actions

    /// All worktrees in sidebar order (sorted by repo, then by creation date).
    var allWorktreesOrdered: [Worktree] {
        repos.flatMap { repo in
            (worktrees[repo.id] ?? []).sorted { $0.createdAt < $1.createdAt }
        }
    }

    /// The repo ID of the first selected worktree (used as "focused repo").
    var focusedRepoID: UUID? {
        guard let firstSelected = selectedWorktreeIDs.first else { return nil }
        for (repoID, wts) in worktrees {
            if wts.contains(where: { $0.id == firstSelected }) {
                return repoID
            }
        }
        return nil
    }

    /// Create a new worktree in the focused repo (or first repo if none focused).
    func newWorktreeInFocusedRepo() {
        let repoID = focusedRepoID ?? repos.first?.id
        guard let repoID else { return }
        createWorktree(repoID: repoID)
    }

    /// Archive the first selected worktree (refuses main worktrees).
    func archiveSelectedWorktree() {
        guard let id = selectedWorktreeIDs.first else { return }
        // Don't archive the main branch worktree
        let allWts = worktrees.values.flatMap { $0 }
        if let wt = allWts.first(where: { $0.id == id }), wt.status == .main { return }
        Task {
            await archiveWorktree(id: id)
        }
    }

    /// Select a worktree by its index in the sidebar order.
    func selectWorktreeByIndex(_ index: Int) {
        let ordered = allWorktreesOrdered
        guard index >= 0, index < ordered.count else { return }
        selectedWorktreeIDs = [ordered[index].id]
    }

    /// Placeholder: new terminal tab in the selected worktree.
    func newTerminalTab() {
        guard let worktreeID = selectedWorktreeIDs.first else { return }
        Task {
            await createTerminal(worktreeID: worktreeID)
        }
    }

    /// Placeholder: close terminal tab.
    func closeTerminalTab() {
        // TODO: implement terminal tab close
    }

    /// Placeholder: split terminal horizontally.
    func splitTerminalHorizontally() {
        // TODO: implement horizontal split
    }

    /// Placeholder: split terminal vertically.
    func splitTerminalVertically() {
        // TODO: implement vertical split
    }

    // MARK: - Helpers

    private func handleConnectionError(_ error: Error) {
        if let dcError = error as? DaemonClientError {
            switch dcError {
            case .daemonNotRunning, .connectionFailed:
                isConnected = false
            default:
                break
            }
        }
    }
}
