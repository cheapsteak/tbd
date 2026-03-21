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
    @Published var layouts: [UUID: LayoutNode] = [:]
    @Published var repoFilter: UUID? = nil

    let daemonClient = DaemonClient()
    let tmuxBridge = TmuxBridge()

    init() {
        Task {
            await connectAndLoadInitialState()
        }
    }

    // MARK: - Connection

    /// Connect to the daemon and fetch initial state.
    func connectAndLoadInitialState() async {
        let didConnect = await daemonClient.connect()
        isConnected = didConnect
        if didConnect {
            await refreshAll()
        } else {
            logger.warning("Could not connect to daemon — is tbdd running?")
        }
    }

    /// Refresh all state from the daemon.
    func refreshAll() async {
        await refreshRepos()
        await refreshWorktrees()
    }

    /// Refresh the repo list.
    func refreshRepos() async {
        do {
            let fetchedRepos = try await daemonClient.listRepos()
            repos = fetchedRepos
        } catch {
            logger.error("Failed to list repos: \(error)")
            handleConnectionError(error)
        }
    }

    /// Refresh worktrees for all repos (or a specific repo).
    func refreshWorktrees(repoID: UUID? = nil) async {
        do {
            let fetched = try await daemonClient.listWorktrees(repoID: repoID, status: .active)
            if let repoID {
                worktrees[repoID] = fetched
            } else {
                // Group by repoID
                var grouped: [UUID: [Worktree]] = [:]
                for wt in fetched {
                    grouped[wt.repoID, default: []].append(wt)
                }
                worktrees = grouped
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

    /// Refresh terminals for a specific worktree.
    func refreshTerminals(worktreeID: UUID) async {
        do {
            let fetched = try await daemonClient.listTerminals(worktreeID: worktreeID)
            terminals[worktreeID] = fetched
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
    func createWorktree(repoID: UUID) async {
        do {
            let wt = try await daemonClient.createWorktree(repoID: repoID)
            worktrees[repoID, default: []].append(wt)
            selectedWorktreeIDs = [wt.id]
            await refreshTerminals(worktreeID: wt.id)
        } catch {
            logger.error("Failed to create worktree: \(error)")
            handleConnectionError(error)
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
        Task {
            await createWorktree(repoID: repoID)
        }
    }

    /// Archive the first selected worktree.
    func archiveSelectedWorktree() {
        guard let id = selectedWorktreeIDs.first else { return }
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
