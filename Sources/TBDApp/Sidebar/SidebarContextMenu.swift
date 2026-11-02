import SwiftUI
import TBDShared

/// Right-click menu for a worktree row. Renders the typed `RowActionMenu`
/// action list (via `RowActionMenuItemsView`), then the surface's own
/// `singleRowItems`. Per-session account facts and switching live in the tab
/// bar, never here.
///
/// The menu follows the selection: for a row in a multi-row selection it is
/// Archive Selection alone (`RowActionMenuActions.actsOnSelection`), so
/// `singleRowItems` are hidden too. The selection is read here, in the
/// menu's own body, not in the row's.
struct SidebarContextMenu<SingleRowItems: View>: View {
    let worktree: Worktree
    var onRename: () -> Void
    /// Items that act on this row alone, shown after the row's actions only
    /// when the menu acts on this row rather than on the selection.
    let singleRowItems: SingleRowItems
    @Environment(AppState.self) var appState

    init(worktree: Worktree, onRename: @escaping () -> Void,
         @ViewBuilder singleRowItems: () -> SingleRowItems) {
        self.worktree = worktree
        self.onRename = onRename
        self.singleRowItems = singleRowItems()
    }

    var body: some View {
        let actions = RowActionMenuActions(
            appState: appState,
            worktree: worktree,
            onRename: onRename,
            followsSelection: true
        )
        RowActionMenuItemsView(actions: actions)
        if !actions.actsOnSelection {
            singleRowItems
        }
    }
}
