import Foundation
import TBDShared

/// A single navigable view state — either a worktree selection (one or more)
/// or a repo selection (showing archived worktrees in the detail pane).
enum NavigationEntry: Equatable {
    case worktrees([UUID])
    case repo(UUID)
}

// MARK: - Sidebar reveal

extension AppState {
    /// Pick which sidebar row a status-bar click should reveal.
    ///
    /// - Exactly one worktree selected → that worktree's ID.
    /// - Multiple selected → the selected worktree whose UUID string sorts
    ///   first alphabetically. UUID strings are stable across runs, so this
    ///   gives a deterministic choice without requiring the caller to know
    ///   sidebar ordering across repos.
    /// - No worktree selected but `selectedRepoID` set → the repo ID (the repo
    ///   header row is tagged with repo.id so scrolling to it works).
    /// - Otherwise → nil.
    nonisolated static func sidebarRevealTarget(
        selectedWorktreeIDs: Set<UUID>,
        worktrees: [UUID: [Worktree]],
        selectedRepoID: UUID?
    ) -> UUID? {
        if selectedWorktreeIDs.count == 1 {
            return selectedWorktreeIDs.first
        } else if selectedWorktreeIDs.count > 1 {
            // Sort by uuidString for a stable, deterministic pick.
            let allWorktreeIDs = Set(worktrees.values.flatMap { $0 }.map(\.id))
            let candidates = selectedWorktreeIDs.filter { allWorktreeIDs.contains($0) }
            return candidates.min(by: { $0.uuidString < $1.uuidString })
                ?? selectedWorktreeIDs.min(by: { $0.uuidString < $1.uuidString })
        } else if let repoID = selectedRepoID {
            return repoID
        } else {
            return nil
        }
    }

    /// Expand the containing repo (if collapsed) and set `pendingScrollToWorktreeID`
    /// so the sidebar scrolls to reveal the currently selected worktree or repo.
    /// Does NOT change selection.
    @MainActor
    func revealSelectionInSidebar() {
        guard let target = Self.sidebarRevealTarget(
            selectedWorktreeIDs: selectedWorktreeIDs,
            worktrees: worktrees,
            selectedRepoID: selectedRepoID
        ) else { return }

        // If the target is a worktree, expand its containing repo before scrolling.
        if let worktree = worktrees.values.flatMap({ $0 }).first(where: { $0.id == target }),
           let repoIdx = repos.firstIndex(where: { $0.id == worktree.repoID }),
           !repos[repoIdx].expanded {
            repos[repoIdx].expanded = true
            let repoID = worktree.repoID
            Task { try? await daemonClient.setRepoExpanded(id: repoID, expanded: true) }
        }

        pendingScrollToWorktreeID = target
    }
}

extension AppState {
    /// Maximum number of entries to retain in the navigation history.
    private static let navigationHistoryCap = 100

    /// Record a new navigation entry. No-op while navigating (back/forward in
    /// progress) or when the entry equals the current head. Truncates any
    /// forward history when the user navigates somewhere new mid-stack.
    func recordNavigation(_ entry: NavigationEntry) {
        guard !isNavigating else { return }
        if navigationIndex >= 0 && navigationIndex < navigationEntries.count {
            if navigationEntries[navigationIndex] == entry { return }
        }
        // Truncate forward history if we're not at the head.
        if navigationIndex < navigationEntries.count - 1 {
            navigationEntries.removeSubrange((navigationIndex + 1)...)
        }
        navigationEntries.append(entry)
        navigationIndex = navigationEntries.count - 1

        // Cap history — drop oldest, keep currentIndex pointing to the same entry.
        while navigationEntries.count > Self.navigationHistoryCap {
            navigationEntries.removeFirst()
            navigationIndex -= 1
        }

        updateNavigationFlags()
    }

    /// Move back to the nearest usable prior entry and apply it. Skips stale
    /// entries (archived/gone worktrees, removed repos) so back never lands on
    /// a dead view. No-op if no usable prior entry exists.
    func navigateBack() {
        guard canGoBack else { return }
        guard let index = usableEntryIndex(from: navigationIndex - 1, step: -1) else {
            // Entries went stale since the flags were last computed (e.g. a
            // worktree vanished without a navigation event) — refresh them so
            // the dead button disables itself instead of staying enabled.
            updateNavigationFlags()
            return
        }
        navigationIndex = index
        withNavigating { applyNavigationEntry(navigationEntries[index]) }
        updateNavigationFlags()
    }

    /// Move forward to the nearest usable next entry and apply it. Skips stale
    /// entries (archived/gone worktrees, removed repos) so forward never lands
    /// on a dead view. No-op if no usable next entry exists.
    func navigateForward() {
        guard canGoForward else { return }
        guard let index = usableEntryIndex(from: navigationIndex + 1, step: 1) else {
            // See navigateBack: refresh stale flags on the dead-end path.
            updateNavigationFlags()
            return
        }
        navigationIndex = index
        withNavigating { applyNavigationEntry(navigationEntries[index]) }
        updateNavigationFlags()
    }

    /// Navigate back to the most recent usable history entry after `archivedID`
    /// was archived. Walks backwards from the current index, skipping entries
    /// that reference the archived worktree or worktrees that no longer exist,
    /// and applies the first usable one. Returns `false` (leaving selection
    /// untouched) when no usable entry exists, so callers can fall back to the
    /// plain empty-selection behavior.
    func navigateBackPastArchived(_ archivedID: UUID) -> Bool {
        guard navigationIndex >= 0, !navigationEntries.isEmpty else { return false }
        let start = min(navigationIndex, navigationEntries.count - 1)
        guard let index = usableEntryIndex(from: start, step: -1, excluding: archivedID) else {
            return false
        }
        navigationIndex = index
        withNavigating { applyNavigationEntry(navigationEntries[index]) }
        updateNavigationFlags()
        return true
    }

    /// Walk `navigationEntries` from `start` in `step` direction (+1/-1) and
    /// return the index of the first usable entry, or nil if none.
    /// Internal (not private) because `updateNavigationFlags()` lives in
    /// AppState.swift (next to its `private(set)` flags) and needs the walker
    /// to compute usability-aware values.
    func usableEntryIndex(
        from start: Int,
        step: Int,
        excluding archivedID: UUID? = nil
    ) -> Int? {
        var index = start
        while index >= 0 && index < navigationEntries.count {
            if isUsableEntry(navigationEntries[index], excluding: archivedID) { return index }
            index += step
        }
        return nil
    }

    /// Whether a history entry is still a valid landing spot: worktree entries
    /// must not reference `archivedID` (when given) and every referenced
    /// worktree must still exist; repo entries must reference a repo we still
    /// know about.
    private func isUsableEntry(_ entry: NavigationEntry, excluding archivedID: UUID? = nil) -> Bool {
        switch entry {
        case .worktrees(let ids):
            guard !ids.isEmpty else { return false }
            if let archivedID, ids.contains(archivedID) { return false }
            let existing = Set(worktrees.values.flatMap { $0 }.map(\.id))
            return ids.allSatisfy { existing.contains($0) }
        case .repo(let id):
            return repos.contains { $0.id == id }
        }
    }

    /// Run `block` with `isNavigating` set so the resulting selection mutations
    /// don't get recorded as new history entries.
    private func withNavigating(_ block: () -> Void) {
        isNavigating = true
        defer { isNavigating = false }
        block()
    }

    /// Apply a navigation entry to the live selection state. Mirrors the work
    /// `selectRepo` would do for repo entries (refreshing archived worktrees).
    private func applyNavigationEntry(_ entry: NavigationEntry) {
        let leavingRepoID = selectedRepoID
        switch entry {
        case .worktrees(let ids):
            if let leavingRepoID { clearRevivingArchived(repoID: leavingRepoID) }
            selectedRepoID = nil
            selectedWorktreeIDs = Set(ids)
            selectionOrder = ids // must come after; didSet above rebuilds from unordered Set
        case .repo(let id):
            if let leavingRepoID, leavingRepoID != id {
                clearRevivingArchived(repoID: leavingRepoID)
            }
            selectedWorktreeIDs = []
            selectedRepoID = id
            Task { await refreshArchivedWorktrees(repoID: id) }
        }
    }

    /// Drop any lingering revive snapshots that belong to the given repo —
    /// called when the user leaves that repo's archived view, so coming back
    /// shows a fresh list without "Revived ✓" rows.
    func clearRevivingArchived(repoID: UUID) {
        revivingArchived = revivingArchived.filter { _, state in
            state.snapshot.repoID != repoID
        }
    }

}
