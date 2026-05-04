import AppKit
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
                let size = mainAreaTerminalSize()
                let wt = try await daemonClient.createWorktree(repoID: repoID, cols: size.cols, rows: size.rows)
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
    /// Mirrors `reviveWithSession`'s lingering-snapshot UX: keeps the row
    /// visible with a status pill until the user navigates away, instead
    /// of yanking them into the now-active worktree.
    func reviveWorktree(id: UUID) async {
        // Idempotency: see `reviveWithSession`. Concurrent invocations
        // would race the `.done` state to nil on the second call's error.
        guard revivingArchived[id] == nil else { return }
        guard let snapshot = archivedWorktrees.values
            .flatMap({ $0 })
            .first(where: { $0.id == id })
        else {
            logger.warning("reviveWorktree: no archived snapshot for \(id, privacy: .public)")
            return
        }
        revivingArchived[id] = .inFlight(snapshot: snapshot)
        advanceArchivedSelectionIfNeeded(worktreeID: id)

        do {
            let size = mainAreaTerminalSize()
            try await daemonClient.reviveWorktree(id: id, cols: size.cols, rows: size.rows)
            revivingArchived[id] = .done(snapshot: snapshot)
            await refreshWorktrees()
            await refreshArchivedWorktrees(repoID: snapshot.repoID)
        } catch {
            revivingArchived.removeValue(forKey: id)
            logger.error("Failed to revive worktree: \(error)")
            showAlert("Couldn't revive worktree: \(error.localizedDescription)", isError: true)
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

    /// Active-worktree path for deep-link navigation. Caller is responsible
    /// for verifying the id exists in `self.worktrees` first.
    @MainActor
    func navigateToActiveWorktree(_ id: UUID) {
        highlightedArchivedWorktreeID = nil
        selectedWorktreeIDs = [id]
        // Only foreground when the AppKit run loop is live — `NSApp` is nil
        // under unit tests, which would crash on the implicit unwrap.
        if NSApplication.shared.isRunning {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    /// Archived-worktree path for deep-link navigation. Async — issues an RPC
    /// to find the worktree across all archived ones, then opens the
    /// archived pane and flashes the row.
    @MainActor
    func navigateToArchivedWorktree(_ id: UUID) async {
        let archived: [Worktree]
        if let override = archivedLookupOverride {
            archived = await override(id)
        } else {
            do {
                archived = try await daemonClient.listWorktrees(
                    repoID: nil, status: .archived
                )
            } catch {
                logger.error("Deep-link archived lookup failed: \(error.localizedDescription)")
                return
            }
        }

        guard let wt = archived.first(where: { $0.id == id }) else {
            logger.warning("Deep link references unknown worktree \(id.uuidString, privacy: .public)")
            return
        }

        selectedWorktreeIDs = []
        selectedRepoID = wt.repoID
        archivedWorktrees[wt.repoID] = archived.filter { $0.repoID == wt.repoID }
        highlightedArchivedWorktreeID = id
        if NSApplication.shared.isRunning {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    /// Public entry point for deep-link navigation. Synchronous fast path
    /// for active worktrees; falls through to the async archived path on a
    /// miss.
    @MainActor
    func navigateToWorktree(_ id: UUID) {
        // Cold-start guard: a tbd:// click can arrive between AppState.init()
        // and the daemon RPC populating `worktrees`. If we fall through to
        // archived lookup now we'll miss real active worktrees. Buffer
        // instead and let connectAndLoadInitialState drain at the end.
        if !isInitialStateLoaded {
            pendingDeepLinkID = id
            return
        }

        let activeMatch = worktrees.values
            .flatMap { $0 }
            .contains(where: { $0.id == id })
        if activeMatch {
            navigateToActiveWorktree(id)
        } else {
            Task { await navigateToArchivedWorktree(id) }
        }
    }

    /// Select a repo to show its archived worktrees in the content pane.
    func selectRepo(id: UUID) {
        highlightedArchivedWorktreeID = nil
        selectedWorktreeIDs = []
        selectedRepoID = id
        Task { await refreshArchivedWorktrees(repoID: id) }
    }

    /// Fetch archived worktrees for a repo.
    func refreshArchivedWorktrees(repoID: UUID) async {
        do {
            let archived = try await daemonClient.listWorktrees(repoID: repoID, status: .archived)
            archivedWorktrees[repoID] = archived
            ensureArchivedSelectionValid(repoID: repoID)
        } catch {
            logger.error("Failed to list archived worktrees: \(error)")
        }
    }

    /// Ensure `selectedArchivedWorktreeIDs[repoID]` points to a row that
    /// actually exists in the archived list (or in `revivingArchived` for that
    /// repo). If unset or stale, set it to the most-recently-archived row.
    /// Also kicks off the session fetch for the newly-selected worktree.
    private func ensureArchivedSelectionValid(repoID: UUID) {
        let archived = (archivedWorktrees[repoID] ?? [])
        let lingering = revivingArchived.values
            .map(\.snapshot)
            .filter { $0.repoID == repoID }
        let allIDs = Set(archived.map(\.id) + lingering.map(\.id))

        let current = selectedArchivedWorktreeIDs[repoID]
        let needsNew = current == nil || !allIDs.contains(current!)
        guard needsNew else { return }

        let mostRecent = archived
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
            .first
        if let pick = mostRecent {
            selectedArchivedWorktreeIDs[repoID] = pick.id
            Task { await fetchSessions(worktreeID: pick.id) }
        } else {
            selectedArchivedWorktreeIDs.removeValue(forKey: repoID)
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
