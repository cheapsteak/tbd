import SwiftUI
import TBDShared

/// Right-click menu for a worktree row. Renders the typed `RowActionMenu`
/// action list (via `RowActionMenuItemsView`). Per-session account facts and
/// switching live in the tab bar, never here.
struct SidebarContextMenu: View {
    let worktree: Worktree
    var onRename: () -> Void
    @EnvironmentObject var appState: AppState

    var body: some View {
        RowActionMenuItemsView(
            actions: RowActionMenuActions(
                appState: appState,
                worktree: worktree,
                onRename: onRename
            )
        )
    }
}
