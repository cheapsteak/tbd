import SwiftUI
import TBDShared

/// The main window's title: the selected worktree's title and notes button,
/// or the selected remote session's name. Both toolbars draw it, SwiftUI's as
/// its `.principal` item and the AppKit one in a hosting view.
struct ToolbarTitleCluster: View {
    @Environment(AppState.self) private var appState

    private var selectedWorktree: Worktree? {
        guard let id = appState.selectedWorktreeIDs.first else { return nil }
        // findWorktree also resolves scratch spaces (repo-less worktrees).
        return appState.findWorktree(id: id)
    }

    var body: some View {
        if let worktree = selectedWorktree {
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
