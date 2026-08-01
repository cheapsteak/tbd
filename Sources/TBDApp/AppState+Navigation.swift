import Foundation
import TBDShared

/// A single navigable view state — a worktree selection (one or more), a
/// repo selection (showing archived worktrees in the detail pane), or a
/// remote-session selection. Remote sessions are first-class here (unlike
/// scratch spaces, which keep the documented back/forward scope cut) because
/// they now render inside a repo's own sidebar section beside local
/// worktrees — a click into one that doesn't populate history reads as a
/// broken back button, not a deliberate omission.
enum NavigationEntry: Equatable {
    case worktrees([UUID])
    case repo(UUID)
    case remoteSession(RemoteSessionSelection)
}

/// Identity of a selected remote-session sidebar row: the provider's
/// registry name plus the provider-minted session id (see
/// `docs/remote-provider-contract.md` § Identity & drift — sessions have no
/// UUID, the provider mints an opaque string id). Parallel to
/// `selectedScratchSection`/`selectedRepoID` and, as of `NavigationEntry
/// .remoteSession`, fully integrated into back/forward history.
struct RemoteSessionSelection: Equatable, Hashable {
    let provider: String
    let sessionID: String
}

// MARK: - Sidebar reveal

extension AppState {
    /// Pick which sidebar row a status-bar click should reveal.
    ///
    /// - Exactly one worktree selected → that worktree's ID.
    /// - Multiple selected → the selected worktree whose UUID string sorts
    ///   first alphabetically among those that still exist in `worktrees` or
    ///   `scratchWorktrees` (scratch spaces live only in the latter).
    ///   Returns `nil` when none of the selected IDs exist (all stale).
    /// - No worktree selected but `selectedRepoID` set → the repo ID (the repo
    ///   header row is tagged with repo.id so scrolling to it works).
    /// - Otherwise → nil.
    nonisolated static func sidebarRevealTarget(
        selectedWorktreeIDs: Set<UUID>,
        worktrees: [UUID: [Worktree]],
        scratchWorktrees: [Worktree],
        selectedRepoID: UUID?
    ) -> UUID? {
        if selectedWorktreeIDs.count == 1 {
            return selectedWorktreeIDs.first
        } else if selectedWorktreeIDs.count > 1 {
            // Sort by uuidString for a stable, deterministic pick.
            let allWorktreeIDs = Set(
                worktrees.values.flatMap { $0 }.map(\.id) + scratchWorktrees.map(\.id)
            )
            let candidates = selectedWorktreeIDs.filter { allWorktreeIDs.contains($0) }
            return candidates.min(by: { $0.uuidString < $1.uuidString })
        } else if let repoID = selectedRepoID {
            return repoID
        } else {
            return nil
        }
    }

    /// Expand the repo containing `worktreeID` (if collapsed) so its row is
    /// part of the rendered sidebar list. Updates local state synchronously
    /// (List rerender + scroll), persists via RPC fire-and-forget. No-op for
    /// unknown IDs. Intentionally repo-scoped (dict-only, not `findWorktree`):
    /// scratch spaces have no repo row to expand.
    @MainActor
    func expandRepoContaining(worktreeID: UUID) {
        guard let worktree = worktrees.values.flatMap({ $0 }).first(where: { $0.id == worktreeID }),
              let repoIdx = repos.firstIndex(where: { $0.id == worktree.repoID }),
              let repoID = worktree.repoID,
              !repos[repoIdx].expanded
        else { return }
        repos[repoIdx].expanded = true
        Task { try? await daemonClient.setRepoExpanded(id: repoID, expanded: true) }
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
        // Built ONCE per walk and threaded through isUsableEntry — rebuilding
        // it per entry made every selection change O(entries × worktrees).
        // allWorktrees includes scratch spaces, so back/forward can land on a
        // live scratch selection instead of skipping it as stale.
        let existingWorktreeIDs = Set(allWorktrees.map(\.id))
        // A remote-session entry is usable iff the daemon's mirror still
        // reports it AND it hasn't been dismissed — `gone` (still reported,
        // just no longer live) stays usable, matching the detail view and
        // context menu, which both still render a gone row (read-only) rather
        // than treating it as absent. Built once per walk for the same
        // reason `existingWorktreeIDs` is.
        let usableRemoteSelections = Set(
            remoteSessions
                .filter { !$0.dismissed }
                .map { RemoteSessionSelection(provider: $0.provider, sessionID: $0.payload.id) }
        )
        var index = start
        while index >= 0 && index < navigationEntries.count {
            if isUsableEntry(
                navigationEntries[index],
                excluding: archivedID,
                existingWorktreeIDs: existingWorktreeIDs,
                usableRemoteSelections: usableRemoteSelections
            ) { return index }
            index += step
        }
        return nil
    }

    /// Whether a history entry is still a valid landing spot: worktree entries
    /// must not reference `archivedID` (when given) and every referenced
    /// worktree must still exist in `existingWorktreeIDs` (built once per walk
    /// by `usableEntryIndex`); repo entries must reference a repo we still
    /// know about; remote-session entries must still be present (and not
    /// dismissed) in `usableRemoteSelections`.
    private func isUsableEntry(
        _ entry: NavigationEntry,
        excluding archivedID: UUID? = nil,
        existingWorktreeIDs: Set<UUID>,
        usableRemoteSelections: Set<RemoteSessionSelection>
    ) -> Bool {
        switch entry {
        case .worktrees(let ids):
            guard !ids.isEmpty else { return false }
            if let archivedID, ids.contains(archivedID) { return false }
            return ids.allSatisfy { existingWorktreeIDs.contains($0) }
        case .repo(let id):
            return repos.contains { $0.id == id }
        case .remoteSession(let selection):
            return usableRemoteSelections.contains(selection)
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
            selectedScratchSection = false
            selectedRemoteProvider = nil
            selectedRemoteSession = nil
            selectedWorktreeIDs = Set(ids)
            selectionOrder = ids // must come after; didSet above rebuilds from unordered Set
        case .repo(let id):
            if let leavingRepoID, leavingRepoID != id {
                clearRevivingArchived(repoID: leavingRepoID)
            }
            selectedWorktreeIDs = []
            selectedRepoID = id
            selectedScratchSection = false
            selectedRemoteProvider = nil
            selectedRemoteSession = nil
            Task { await refreshArchivedWorktrees(repoID: id) }
            Task { await refreshReapRecords(repoID: id) }
        case .remoteSession(let selection):
            // Shares `activateRemoteSession` with `selectRemoteSession` (see
            // its doc comment) rather than calling `selectRemoteSession`
            // directly — that call also records a NEW navigation entry via
            // `recordNavigation`, which happens to be a no-op here (guarded
            // by `isNavigating`, set by the caller's `withNavigating`) but
            // routing through the shared, recording-free helper keeps this
            // case symmetric with `.worktrees`/`.repo` above, which likewise
            // never call their own "select" functions and instead apply
            // state directly. Plus the same `leavingRepoID` revive-snapshot
            // cleanup those two cases do — `activateRemoteSession` alone
            // doesn't do this (a plain click never reaches this path).
            // Deliberately resets to the DEFAULT tab (does not restore
            // whichever tab — Attach/Log — was showing when this entry was
            // recorded): worktree entries don't carry per-tab/pane state
            // either, so this keeps remote sessions consistent with that
            // precedent rather than inventing tab-level history.
            if let leavingRepoID { clearRevivingArchived(repoID: leavingRepoID) }
            activateRemoteSession(selection, tab: nil)
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

extension AppState {
    /// Select a remote-session sidebar row: shows `RemoteSessionDetailView`
    /// (Task 10) in the content pane. Mirrors `selectScratchSection()`/
    /// `selectRepo(id:)` — clears the other three mutually-exclusive sidebar
    /// selections. Also clears this session's unread entry, mirroring
    /// `markSelectedWorktreesAsRead`'s optimistic local clear-on-select — the
    /// daemon has no per-remote-session read-state to round-trip, so this is
    /// purely a local bookkeeping clear. Records a navigation entry (see
    /// `activateRemoteSession`) so back/forward can return here — remote
    /// sessions now sit inside a repo's own sidebar section beside local
    /// worktrees, so they participate in history exactly like a worktree
    /// selection does (unlike scratch spaces, which keep the documented
    /// scope cut).
    ///
    /// - Parameter tab: an optional one-shot hint for which tab the detail
    ///   view should land on (set by a context-menu action like "View Log"
    ///   or "Attach" that jumps straight to a tab). `nil` (the default, used
    ///   by a plain row click) means "default tab" — always overwrites any
    ///   stale leftover hint from a previous selection.
    func selectRemoteSession(provider: String, sessionID: String, tab: RemoteSessionDetailTab? = nil) {
        let selection = RemoteSessionSelection(provider: provider, sessionID: sessionID)
        activateRemoteSession(selection, tab: tab)
        recordNavigation(.remoteSession(selection))
    }

    /// Select a provider header without attaching to a session. The desk is a
    /// read-only projection of data already mirrored in AppState.
    func selectRemoteProvider(_ provider: String) {
        highlightedArchivedWorktreeID = nil
        selectedWorktreeIDs = []
        selectedRepoID = nil
        selectedScratchSection = false
        selectedRemoteSession = nil
        remoteSessionRequestedTab = nil
        selectedRemoteProvider = provider
    }

    /// Shared state transition for landing on a remote-session selection —
    /// used by both a plain click/context-menu action (`selectRemoteSession`,
    /// which additionally records a navigation entry) and back/forward
    /// replay (`applyNavigationEntry`, which must NOT record a new entry
    /// while replaying one — `recordNavigation` guards on `isNavigating`,
    /// but `selectRemoteSession` isn't reused directly there so the two
    /// call sites stay symmetric with how `.worktrees`/`.repo` apply state
    /// directly rather than through their own "select" functions).
    ///
    /// Clears the other three mutually-exclusive selections, sets the tab
    /// hint, clears this session's unread entry, and feeds the
    /// attach-lifecycle recency log (`touchAttachedRemoteSession`) — a click
    /// AND a back/forward landing both count as "viewed" for keep-alive
    /// purposes, matching how a worktree click OR a back/forward landing on
    /// it both count for `touchVisitedWorktree`.
    ///
    /// Explicit-detach state rule: an already-detached session's flag
    /// (`explicitlyDetachedRemoteSessions`) is cleared — allowing it to
    /// auto-attach again — only when this call is a genuine NEW transition
    /// (the previously selected session, if any, differs from `selection`)
    /// or an explicit re-attach request (`tab == .attach`, the context
    /// menu's "Attach" item). A REDUNDANT reselection of the session that's
    /// ALREADY current, with no `.attach` tab request, changes nothing —
    /// this is the rule that keeps a detach from looping: the pty exiting
    /// while its row stays the current selection must never by itself cause
    /// a respawn, since nothing re-invokes this function merely because the
    /// selection didn't change.
    private func activateRemoteSession(_ selection: RemoteSessionSelection, tab: RemoteSessionDetailTab?) {
        let isTransition = selectedRemoteSession != selection
        highlightedArchivedWorktreeID = nil
        selectedWorktreeIDs = []
        selectedRepoID = nil
        selectedScratchSection = false
        selectedRemoteProvider = nil
        selectedRemoteSession = selection
        remoteSessionRequestedTab = tab
        unreadByRemoteSession[selection] = nil
        touchAttachedRemoteSession(selection)
        if isTransition || tab == .attach {
            clearRemoteSessionDetachedFlag(selection)
        }
    }
}
