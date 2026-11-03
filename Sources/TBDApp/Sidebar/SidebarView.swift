import SwiftUI

/// The main window's sidebar column: the native outline and the pinned dock
/// fill it, down to the window's bottom edge, beside the status bar at the
/// foot of the content pane. Add Repository is the outline's last row. The
/// controllers observe `AppState` themselves and carry their own reveal
/// handling, so this view reads nothing.
struct SidebarView: View {
    var body: some View {
        NativeSidebarView()
    }
}
