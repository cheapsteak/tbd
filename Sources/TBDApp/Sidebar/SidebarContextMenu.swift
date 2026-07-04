import SwiftUI
import TBDShared

/// Right-click menu for a worktree row. Renders exactly the shared
/// `RowActionMenu` action list (via `RowActionMenuItemsView`) — the SAME items,
/// order, and behavior as the hover "…" menu's action tail. The account section
/// is contributed only by the "…" menu, never here.
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
