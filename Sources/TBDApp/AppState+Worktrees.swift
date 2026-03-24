import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+Worktrees")

extension AppState {
    // MARK: - Worktree Actions

    /// Create a new worktree in a repo.
    /// The daemon returns a worktree with `status = .creating` immediately.
    /// The 2-second polling will pick up the status change to `.active` when creation completes.
    func createWorktree(repoID: UUID) {
        Task {
            do {
                let wt = try await daemonClient.createWorktree(repoID: repoID)
                worktrees[repoID, default: []].append(wt)
                selectedWorktreeIDs = [wt.id]
                editingWorktreeID = wt.id
            } catch {
                logger.error("Failed to create worktree: \(error)")
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
        // For creating worktrees, just update locally — the name will be applied when creation finishes
        let isCreating = worktrees.values.flatMap({ $0 }).first(where: { $0.id == id })?.status == .creating
        if isCreating {
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
        if let wt = allWts.first(where: { $0.id == id }), wt.status == .main || wt.status == .creating { return }
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
