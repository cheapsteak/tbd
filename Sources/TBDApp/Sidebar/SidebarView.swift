import SwiftUI

/// The main window's sidebar column: the native outline and the pinned dock
/// fill it, and the shared footer sits beneath them. The divider topping the
/// dock is the native container's, so the footer follows the dock directly.
/// The column reaches the window's bottom edge, and the footer shares the
/// status bar's height (`WindowBottomBarMetrics`), so the two line up across
/// the split. The controllers observe `AppState` themselves and carry their
/// own reveal handling, so this view reads nothing.
struct SidebarView: View {
    var body: some View {
        VStack(spacing: 0) {
            NativeSidebarView()
            SidebarFooter()
                .background(.bar)
        }
    }
}
