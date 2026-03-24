import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+Worktrees")

extension AppState {
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
        let worktreeName = worktrees.values.flatMap { $0 }.first { $0.id == id }?.displayName ?? "worktree"
        do {
            try await daemonClient.archiveWorktree(id: id, force: force)
            for repoID in worktrees.keys {
                worktrees[repoID]?.removeAll { $0.id == id }
            }
            selectedWorktreeIDs.remove(id)
            terminals.removeValue(forKey: id)
            logger.info("Archived \(worktreeName)")
        } catch {
            logger.error("Failed to archive worktree: \(error)")
            showAlert("Archive failed: \(error)", isError: true)
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
}
