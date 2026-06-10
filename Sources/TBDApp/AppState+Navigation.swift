import Foundation

/// A single navigable view state — either a worktree selection (one or more)
/// or a repo selection (showing archived worktrees in the detail pane).
enum NavigationEntry: Equatable {
    case worktrees([UUID])
    case repo(UUID)
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

    /// Move back one entry in the history and apply it. No-op if no prior entry.
    func navigateBack() {
        guard canGoBack else { return }
        navigationIndex -= 1
        let entry = navigationEntries[navigationIndex]
        withNavigating { applyNavigationEntry(entry) }
        updateNavigationFlags()
    }

    /// Move forward one entry in the history and apply it. No-op if no next entry.
    func navigateForward() {
        guard canGoForward else { return }
        navigationIndex += 1
        let entry = navigationEntries[navigationIndex]
        withNavigating { applyNavigationEntry(entry) }
        updateNavigationFlags()
    }

    /// Navigate back to the most recent usable history entry after `archivedID`
    /// was archived. Walks backwards from the current index, skipping entries
    /// that reference the archived worktree or worktrees that no longer exist,
    /// and applies the first usable one. Returns `false` (leaving selection
    /// untouched) when no usable entry exists, so callers can fall back to the
    /// plain empty-selection behavior.
    @discardableResult
    func navigateBackPastArchived(_ archivedID: UUID) -> Bool {
        guard navigationIndex >= 0, !navigationEntries.isEmpty else { return false }
        let start = min(navigationIndex, navigationEntries.count - 1)
        for index in stride(from: start, through: 0, by: -1) {
            let entry = navigationEntries[index]
            guard isUsableEntry(entry, excluding: archivedID) else { continue }
            navigationIndex = index
            withNavigating { applyNavigationEntry(entry) }
            updateNavigationFlags()
            return true
        }
        return false
    }

    /// Whether a history entry is still a valid landing spot once `archivedID`
    /// is gone: worktree entries must not reference the archived ID and every
    /// referenced worktree must still exist; repo entries must reference a
    /// repo we still know about.
    private func isUsableEntry(_ entry: NavigationEntry, excluding archivedID: UUID) -> Bool {
        switch entry {
        case .worktrees(let ids):
            guard !ids.isEmpty, !ids.contains(archivedID) else { return false }
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
