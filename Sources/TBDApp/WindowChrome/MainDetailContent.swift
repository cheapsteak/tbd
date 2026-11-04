import Foundation
import TBDShared

/// What the main window's detail area shows, decided in one place. The detail
/// area's views choose their content from it (`MainDetailArea`'s tab through
/// `DetailSectionHostPager.targetTab`, `OtherSectionContent`,
/// `TerminalContainerView`), and the toolbar's snapshot reads
/// `showsWorktreeTabBar` from it, so the toolbar never gives up its title for
/// a page that draws no tab bar, nor keeps it over one that does. Spec:
/// `docs/specs/2026-11-02-tabs-in-toolbar-design.md`, "Who draws the row".
enum MainDetailContent: Equatable {
    /// The `.remote` tab: a selected remote session.
    case remoteSession
    /// The `.providerDesk` tab: a selected remote provider.
    case providerDesk
    /// The daemon is not connected.
    case disconnected
    /// The sidebar's Scratch section.
    case scratchSection
    /// No repository is registered: the empty state.
    case noRepositories
    /// A repo's own page.
    case repo(UUID)
    /// Nothing is selected.
    case nothingSelected
    /// Several worktrees: the multi-select grid, which draws no tab bar.
    case multipleWorktrees
    /// One worktree, drawn by `SingleWorktreeView`.
    case worktree(UUID)

    /// Whether the detail area draws a worktree's tab bar: only
    /// `SingleWorktreeView` does, and only for a worktree it finds
    /// (`worktreeExists`); for one it cannot find it shows "Worktree not
    /// found". Asked separately from the content, so a view that only
    /// chooses its content never reads the worktree lists.
    func showsWorktreeTabBar(worktreeExists: (UUID) -> Bool) -> Bool {
        guard case .worktree(let id) = self else { return false }
        return worktreeExists(id)
    }

    /// The whole detail area: the tab `DetailSectionHostPager.targetTab`
    /// brings to the front, and on the `.other` tab what `otherTab` shows.
    nonisolated static func resolve(
        targetTab: DetailSectionHostPager.DetailTab, other: () -> MainDetailContent
    ) -> MainDetailContent {
        switch targetTab {
        case .remote: return .remoteSession
        case .providerDesk: return .providerDesk
        case .other: return other()
        }
    }

    /// What the `.other` tab shows (`OtherSectionContent`), in its order:
    /// the disconnected message, the Scratch section, the empty state, a
    /// repo's page, then the worktree selection.
    nonisolated static func otherTab(
        isConnected: Bool,
        scratchSectionSelected: Bool,
        hasRepositories: Bool,
        selectedRepoID: UUID?,
        selectedWorktreeIDs: Set<UUID>
    ) -> MainDetailContent {
        guard isConnected else { return .disconnected }
        if scratchSectionSelected { return .scratchSection }
        guard hasRepositories else { return .noRepositories }
        if let selectedRepoID { return .repo(selectedRepoID) }
        return worktreeSelection(selectedWorktreeIDs)
    }

    /// What `TerminalContainerView` shows for the worktree selection: nothing,
    /// the multi-select grid, or the one worktree.
    nonisolated static func worktreeSelection(_ selectedWorktreeIDs: Set<UUID>) -> MainDetailContent {
        guard let first = selectedWorktreeIDs.first else { return .nothingSelected }
        guard selectedWorktreeIDs.count == 1 else { return .multipleWorktrees }
        return .worktree(first)
    }

    /// The detail area as `appState` has it.
    @MainActor
    static func current(in appState: AppState) -> MainDetailContent {
        let tab = DetailSectionHostPager.targetTab(
            isConnected: appState.isConnected,
            selectedRemoteSession: appState.selectedRemoteSession,
            selectedRemoteProvider: appState.selectedRemoteProvider)
        return resolve(targetTab: tab) { otherTab(in: appState) }
    }

    /// The `.other` tab as `appState` has it.
    @MainActor
    static func otherTab(in appState: AppState) -> MainDetailContent {
        otherTab(
            isConnected: appState.isConnected,
            scratchSectionSelected: appState.selectedScratchSection,
            hasRepositories: !appState.repos.isEmpty,
            selectedRepoID: appState.selectedRepoID,
            selectedWorktreeIDs: appState.selectedWorktreeIDs)
    }
}

extension AppState {
    /// Whether the detail area draws a worktree's tab bar
    /// (`MainDetailContent.showsWorktreeTabBar(worktreeExists:)`), and so
    /// whether the panes draw the window's top row. The toolbar's
    /// `MainToolbarLayoutState.panesDrawTopRow` is the same decision, made
    /// from the same function.
    var showsWorktreeTabBar: Bool {
        MainDetailContent.current(in: self).showsWorktreeTabBar { findWorktree(id: $0) != nil }
    }
}
