import SwiftUI
import TBDShared

/// The main window's title: the selected worktree's title and notes button,
/// or the selected remote session's name. Both toolbars draw it, SwiftUI's as
/// its `.principal` item and the AppKit one in a hosting view.
///
/// `appState` is passed in, not read from the environment, so the view has no
/// `@Environment` dependency inside the `.principal` toolbar item — the
/// `WorktreeTitleView` convention.
struct ToolbarTitleCluster: View {
    let appState: AppState

    /// The worktree the cluster names: the first selected one.
    private static func selectedWorktree(in appState: AppState) -> Worktree? {
        guard let id = appState.selectedWorktreeIDs.first else { return nil }
        // findWorktree also resolves scratch spaces (repo-less worktrees).
        return appState.findWorktree(id: id)
    }

    /// The text the cluster shows as its main title: the selected worktree's
    /// name, as `WorktreeTitleView` shows it, or the selected remote
    /// session's. `nil` when it shows neither. The AppKit toolbar's overflow
    /// row for the title shows the same text.
    static func mainTitle(in appState: AppState) -> String? {
        if let worktree = selectedWorktree(in: appState) {
            return worktree.displayName
        }
        if let selection = appState.selectedRemoteSession {
            return appState.remoteSessionDisplayName(for: selection)
        }
        return nil
    }

    var body: some View {
        if let worktree = Self.selectedWorktree(in: appState) {
            WorktreeTitleView(
                appState: appState,
                worktree: worktree,
                repoName: worktree.repoID.flatMap { appState.repoName(for: $0) }
            )
        } else if let selection = appState.selectedRemoteSession {
            // A Remote-section row selects no worktree; name the session the
            // way `WorktreeTitleView` names a local one. (An adopted lane's
            // row IS a worktree selection and takes the branch above.)
            Text(appState.remoteSessionDisplayName(for: selection))
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
