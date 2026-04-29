import Foundation

/// A single navigable view state — either a worktree selection (one or more)
/// or a repo selection (showing archived worktrees in the detail pane).
enum NavigationEntry: Equatable {
    case worktrees(Set<UUID>)
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
        switch entry {
        case .worktrees(let ids):
            selectedRepoID = nil
            selectedWorktreeIDs = ids
        case .repo(let id):
            selectedWorktreeIDs = []
            selectedRepoID = id
            Task { await refreshArchivedWorktrees(repoID: id) }
        }
    }

}
