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
    /// When `parentWorktreeID` is non-nil, the new worktree is created as a
    /// nested child of that worktree (must be in the same repo).
    /// When `existingBranch` is non-nil, the daemon checks out that branch
    /// into a new worktree (no auto-generated `tbd/*` branch); the optimistic
    /// placeholder uses the branch's local name so the row looks right
    /// immediately.
    func createWorktree(repoID: UUID, parentWorktreeID: UUID? = nil, existingBranch: BranchInfo? = nil) {
        // Optimistic placeholder so the row appears instantly. When picking an
        // existing branch we use its local name so the placeholder name
        // doesn't briefly show a fake `tbd/*` value.
        let placeholderName: String
        let placeholderBranch: String
        if let existingBranch {
            placeholderName = existingBranch.localName
            placeholderBranch = existingBranch.localName
        } else {
            placeholderName = NameGenerator.generate()
            placeholderBranch = "tbd/\(placeholderName)"
        }
        let placeholder = Worktree(
            repoID: repoID,
            name: placeholderName,
            displayName: placeholderName,
            branch: placeholderBranch,
            path: "",
            status: .creating,
            tmuxServer: "",
            parentWorktreeID: parentWorktreeID
        )
        pendingWorktreeIDs.insert(placeholder.id)
        worktrees[repoID, default: []].append(placeholder)
        selectedWorktreeIDs = [placeholder.id]
        editingWorktreeID = placeholder.id

        Task {
            defer { pendingWorktreeIDs.remove(placeholder.id) }
            do {
                let size = mainAreaTerminalSize()
                let wt = try await daemonClient.createWorktree(
                    repoID: repoID,
                    branch: existingBranch?.name,
                    cols: size.cols, rows: size.rows,
                    parentWorktreeID: parentWorktreeID,
                    useExistingBranch: existingBranch != nil
                )
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

    /// List local + remote tracking branches for a repo, for the existing-
    /// branch picker on the sidebar `+` button. Rethrows so the picker can
    /// distinguish a fetch failure from a genuinely empty branch list.
    func listBranches(repoID: UUID) async throws -> [BranchInfo] {
        do {
            return try await daemonClient.listBranches(repoID: repoID)
        } catch {
            logger.error("Failed to list branches: \(error)")
            handleConnectionError(error)
            throw error
        }
    }

    /// Archive a worktree.
    func archiveWorktree(id: UUID, force: Bool = false) async {
        let worktreeName = worktrees.values.flatMap { $0 }.first { $0.id == id }?.displayName ?? "worktree"
        do {
            try await daemonClient.archiveWorktree(id: id, force: force)
            removeArchivedWorktreeFromState(id: id)
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
            recentlyArchivedWorktreeIDs.removeValue(forKey: id)
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
    /// for verifying the id exists in `self.worktrees` first. When
    /// `terminalID` is non-nil, also switches the worktree's active tab to
    /// the one rendering that terminal (live transcript or terminal pane);
    /// silently falls back to current selection when no tab matches.
    @MainActor
    func navigateToActiveWorktree(_ id: UUID, terminalID: UUID? = nil) {
        highlightedArchivedWorktreeID = nil
        selectedWorktreeIDs = [id]
        // Expand the containing repo so the row is part of the rendered list
        // before we ask the sidebar to scroll to it. Update local state
        // synchronously (List rerender + scroll), persist via RPC fire-and-forget.
        if let worktree = worktrees.values.flatMap({ $0 }).first(where: { $0.id == id }),
           let repoIdx = repos.firstIndex(where: { $0.id == worktree.repoID }),
           !repos[repoIdx].expanded {
            repos[repoIdx].expanded = true
            let repoID = worktree.repoID
            Task { try? await daemonClient.setRepoExpanded(id: repoID, expanded: true) }
        }
        pendingScrollToWorktreeID = id
        // Switch to the originating terminal's tab when one matches. Both
        // `.terminal` and `.liveTranscript` panes count as matches — clicking
        // the banner should land the user on whichever surface the worktree
        // currently exposes for that terminal. If neither match exists (e.g.
        // the terminal was deleted, or surfaced only via the pinned dock),
        // we silently keep whatever tab was active before.
        if let terminalID, let arr = tabs[id] {
            if let idx = arr.firstIndex(where: { tab in
                switch tab.content {
                case .terminal(let tid): return tid == terminalID
                case .liveTranscript(_, let tid): return tid == terminalID
                default: return false
                }
            }) {
                setActiveTab(worktreeID: id, tabIndex: idx)
            }
        }
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
        archivedWorktreesHasMore[wt.repoID] = false
        highlightedArchivedWorktreeID = id
        if NSApplication.shared.isRunning {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    /// Public entry point for deep-link navigation. Synchronous fast path
    /// for active worktrees; falls through to the async archived path on a
    /// miss. When `terminalID` is non-nil, the active-worktree path also
    /// switches to the originating tab. The archived path silently drops
    /// `terminalID` — archived worktrees have no live terminals to focus.
    @MainActor
    func navigateToWorktree(_ id: UUID, terminalID: UUID? = nil) {
        // Cold-start guard: a tbd:// click can arrive between AppState.init()
        // and the daemon RPC populating `worktrees`. If we fall through to
        // archived lookup now we'll miss real active worktrees. Buffer
        // instead and let connectAndLoadInitialState drain at the end.
        if !isInitialStateLoaded {
            pendingDeepLinkID = id
            pendingDeepLinkTerminalID = terminalID
            return
        }

        let activeMatch = worktrees.values
            .flatMap { $0 }
            .contains(where: { $0.id == id })
        if activeMatch {
            navigateToActiveWorktree(id, terminalID: terminalID)
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

    private static let archivedPageSize = 50

    /// Fetch archived worktrees for a repo, preserving any pages the user has
    /// already loaded (re-fetches up to `max(currentCount, pageSize)` items).
    func refreshArchivedWorktrees(repoID: UUID) async {
        let currentCount = archivedWorktrees[repoID]?.count ?? 0
        let fetchCount = max(currentCount, Self.archivedPageSize)
        let knownExhausted = currentCount > 0 && currentCount % Self.archivedPageSize != 0
        do {
            let archived = try await daemonClient.listWorktrees(
                repoID: repoID, status: .archived,
                limit: fetchCount
            )
            archivedWorktrees[repoID] = archived
            archivedWorktreesHasMore[repoID] = knownExhausted ? false : archived.count >= fetchCount
            ensureArchivedSelectionValid(repoID: repoID)
        } catch {
            logger.error("Failed to list archived worktrees: \(error)")
        }
    }

    /// Load the next page of archived worktrees, appending to the existing list.
    func loadMoreArchivedWorktrees(repoID: UUID) async {
        guard isLoadingMoreArchived[repoID] != true else { return }
        isLoadingMoreArchived[repoID] = true
        defer { isLoadingMoreArchived[repoID] = false }

        let currentCount = archivedWorktrees[repoID]?.count ?? 0
        do {
            let more = try await daemonClient.listWorktrees(
                repoID: repoID, status: .archived,
                limit: Self.archivedPageSize, offset: currentCount
            )
            if archivedWorktrees[repoID]?.count == currentCount {
                archivedWorktrees[repoID, default: []].append(contentsOf: more)
            }
            archivedWorktreesHasMore[repoID] = more.count >= Self.archivedPageSize
        } catch {
            logger.error("Failed to load more archived worktrees: \(error)")
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

    // MARK: - Reorder top-level

    /// Reorder ONLY the top-level worktrees of a repo (parentWorktreeID == nil),
    /// triggered by SwiftUI `.onMove` whose indices index the top-level ForEach.
    /// Nested children stay attached to their parents — only top-level sortOrders change.
    /// Updates locally first (optimistic), then persists via RPC; rolls back on error.
    func reorderTopLevelWorktrees(repoID: UUID, fromOffsets source: IndexSet, toOffset destination: Int) {
        let previous = worktrees[repoID]
        var rows = (worktrees[repoID] ?? [])
        // Snapshot the top-level order BEFORE the move (matches the ForEach).
        var topLevel = rows
            .filter { ($0.status == .active || $0.status == .creating) && $0.parentWorktreeID == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
        logger.debug("reorderTopLevel BEFORE: \(topLevel.map(\.displayName).joined(separator: " | "), privacy: .public) source=\(Array(source), privacy: .public) destination=\(destination, privacy: .public)")
        // guard: source/destination can outlive the snapshot they were captured against
        if topLevel.isEmpty || source.contains(where: { $0 >= topLevel.count }) || destination > topLevel.count {
            logger.warning("reorderTopLevel skipped: stale indices (topLevel.count=\(topLevel.count, privacy: .public) source=\(Array(source), privacy: .public) destination=\(destination, privacy: .public))")
            return
        }
        // Apply the swap to derive the new top-level order.
        topLevel.move(fromOffsets: source, toOffset: destination)
        logger.debug("reorderTopLevel AFTER: \(topLevel.map(\.displayName).joined(separator: " | "), privacy: .public)")

        // Optimistic local update: reassign sortOrders for the new top-level order.
        for (i, wt) in topLevel.enumerated() {
            if let idx = rows.firstIndex(where: { $0.id == wt.id }) {
                rows[idx].sortOrder = i
            }
        }
        worktrees[repoID] = rows

        // Persist via the bulk reorder RPC. Daemon renumbers all listed worktrees
        // to contiguous sortOrders matching the new top-level order, avoiding
        // gappy/non-contiguous values from prior individual moves.
        let orderedIDs = topLevel.map(\.id)
        Task {
            do {
                logger.debug("RPC worktree.reorder ids=\(orderedIDs.map { $0.uuidString.prefix(8) }.joined(separator: ","), privacy: .public)")
                try await daemonClient.reorderWorktrees(repoID: repoID, worktreeIDs: orderedIDs)
            } catch {
                logger.error("reorderTopLevelWorktrees RPC failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run { self.worktrees[repoID] = previous }
            }
        }
    }

    // MARK: - Move (nested worktrees)

    /// Move a worktree to a new parent (or top-level) and sortOrder.
    /// Optimistic local update; rolls back on RPC error.
    func moveWorktree(id: UUID, newParentID: UUID?, newSortOrder: Int) {
        let snapshot = worktrees
        if let repoID = repoIDForWorktree(id), var rows = worktrees[repoID] {
            if let idx = rows.firstIndex(where: { $0.id == id }) {
                rows[idx].parentWorktreeID = newParentID
                rows[idx].sortOrder = newSortOrder
                worktrees[repoID] = rows
            }
        }
        Task {
            do {
                try await daemonClient.moveWorktree(
                    worktreeID: id, newParentID: newParentID, newSortOrder: newSortOrder
                )
            } catch {
                logger.error("moveWorktree failed: \(error.localizedDescription)")
                await MainActor.run { self.worktrees = snapshot }
            }
        }
    }

    /// All worktrees whose parentWorktreeID == parentID, across all repos, in sortOrder.
    /// Only active or creating worktrees are returned.
    func children(of parentID: UUID) -> [Worktree] {
        worktrees.values
            .flatMap { $0 }
            .filter { $0.parentWorktreeID == parentID && ($0.status == .active || $0.status == .creating) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Find a worktree by id across all repos.
    func findWorktree(id: UUID) -> Worktree? {
        for (_, rows) in worktrees {
            if let wt = rows.first(where: { $0.id == id }) { return wt }
        }
        return nil
    }

    /// Repo ID of the repo containing the given worktree, if any.
    private func repoIDForWorktree(_ id: UUID) -> UUID? {
        for (rid, rows) in worktrees where rows.contains(where: { $0.id == id }) {
            return rid
        }
        return nil
    }

    // MARK: - Keyboard Shortcut Actions

    /// All worktrees in **visual sidebar order**: each repo's main row (if any),
    /// then a depth-first walk of top-level worktrees followed by their
    /// descendants. Matches what the user sees in the sidebar so cmd+N keyboard
    /// shortcuts (via `selectWorktreeByIndex`) land on the right row.
    ///
    /// `sortOrder` is scoped per sibling group (top-level OR children-of-X), so
    /// a flat repo-wide sort by `sortOrder` would collapse two namespaces
    /// together and put nested children with `sortOrder: 0` ahead of top-level
    /// rows with `sortOrder: 1+`.
    var allWorktreesOrdered: [Worktree] {
        var result: [Worktree] = []
        for repo in repos {
            let inRepo = worktrees[repo.id] ?? []
            // Main row first (if present in this repo).
            if let main = inRepo.first(where: { $0.status == .main }) {
                result.append(main)
            }
            // Top-level active/creating worktrees in this repo, sorted by sortOrder.
            let topLevel = inRepo
                .filter { ($0.status == .active || $0.status == .creating) && $0.parentWorktreeID == nil }
                .sorted { $0.sortOrder < $1.sortOrder }
            for wt in topLevel {
                appendSubtree(wt, depth: 0, into: &result)
            }
        }
        return result
    }

    /// Depth-first append: the worktree itself, then its children (across all
    /// repos, since a child can have a different `repoID` from its parent),
    /// recursively. Used by `allWorktreesOrdered` to match sidebar order.
    /// Caps recursion at 50 to mirror `WorktreeSubtreeView.kMaxSubtreeDepth`
    /// in case a cyclic parent chain ever makes it into the in-memory state
    /// (DB-side cycle guards make this unlikely, but the keyboard-nav path
    /// shouldn't blow the stack while the renderer gracefully degrades).
    private func appendSubtree(_ wt: Worktree, depth: Int, into result: inout [Worktree]) {
        result.append(wt)
        guard depth < 50 else { return }
        for child in children(of: wt.id) {
            appendSubtree(child, depth: depth + 1, into: &result)
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

    /// Backward-compatible wrapper for callers that still ask to close the
    /// current terminal tab. The close target now comes only from focus.
    func closeTerminalTab() {
        closeFocusedTab()
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
