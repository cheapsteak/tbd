import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+Worktrees")

extension AppState {
    // MARK: - Worktree Actions

    /// Create a new worktree in a repo.
    /// Shows an optimistic placeholder immediately, then replaces it with the
    /// real worktree once the daemon responds.
    func createWorktree(repoID: UUID) {
        // Optimistic placeholder so the row appears instantly
        let placeholderName = NameGenerator.generate()
        let placeholder = Worktree(
            repoID: repoID,
            name: placeholderName,
            displayName: placeholderName,
            branch: "tbd/\(placeholderName)",
            path: "",
            status: .creating,
            tmuxServer: ""
        )
        pendingWorktreeIDs.insert(placeholder.id)
        worktrees[repoID, default: []].append(placeholder)
        selectedWorktreeIDs = [placeholder.id]
        editingWorktreeID = placeholder.id

        Task {
            defer { pendingWorktreeIDs.remove(placeholder.id) }
            do {
                let wt = try await daemonClient.createWorktree(repoID: repoID)
                // Replace the placeholder with the real worktree
                if let idx = worktrees[repoID]?.firstIndex(where: { $0.id == placeholder.id }) {
                    worktrees[repoID]?[idx] = wt
                }
                selectedWorktreeIDs = [wt.id]
                editingWorktreeID = wt.id
            } catch {
                // Remove the placeholder on failure
                worktrees[repoID]?.removeAll { $0.id == placeholder.id }
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
        // Find the repo before reviving so we can refresh the archived list
        let repoID = archivedWorktrees.first(where: { $0.value.contains { $0.id == id } })?.key
        do {
            try await daemonClient.reviveWorktree(id: id)
            await refreshWorktrees()
            selectedWorktreeIDs = [id]
            if let repoID {
                await refreshArchivedWorktrees(repoID: repoID)
            }
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

    // MARK: - Archived Worktrees

    /// Select a repo to show its archived worktrees in the content pane.
    func selectRepo(id: UUID) {
        selectedWorktreeIDs = []
        selectedRepoID = id
        Task { await refreshArchivedWorktrees(repoID: id) }
    }

    /// Fetch archived worktrees for a repo.
    func refreshArchivedWorktrees(repoID: UUID) async {
        do {
            let archived = try await daemonClient.listWorktrees(repoID: repoID, status: .archived)
            archivedWorktrees[repoID] = archived
        } catch {
            logger.error("Failed to list archived worktrees: \(error)")
        }
    }

    // MARK: - Reorder

    /// Reorder worktrees within a repo. Updates locally first (optimistic), then persists via RPC.
    /// Rolls back local state if the RPC call fails.
    func reorderWorktrees(repoID: UUID, fromOffsets source: IndexSet, toOffset destination: Int) {
        let previousWorktrees = worktrees[repoID]
        guard var repoWorktrees = worktrees[repoID]?.filter({ $0.status == .active || $0.status == .creating }) else { return }
        repoWorktrees.move(fromOffsets: source, toOffset: destination)
        for i in repoWorktrees.indices {
            repoWorktrees[i].sortOrder = i
        }

        // Rebuild the full array: keep main/other statuses in place, replace active/creating with reordered
        let others = (worktrees[repoID] ?? []).filter { $0.status != .active && $0.status != .creating }
        worktrees[repoID] = others + repoWorktrees

        // Persist via RPC
        let worktreeIDs = repoWorktrees.map(\.id)
        Task {
            do {
                try await daemonClient.reorderWorktrees(repoID: repoID, worktreeIDs: worktreeIDs)
            } catch {
                logger.error("Failed to reorder worktrees: \(error)")
                worktrees[repoID] = previousWorktrees
            }
        }
    }

    // MARK: - Keyboard Shortcut Actions

    /// All worktrees in sidebar order (sorted by repo, then by sortOrder).
    var allWorktreesOrdered: [Worktree] {
        repos.flatMap { repo in
            (worktrees[repo.id] ?? []).sorted { $0.sortOrder < $1.sortOrder }
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
