import SwiftUI
import TBDShared

/// The Watch Desk's fixed slot, directly above the Day/Night toggle.
///
/// Deliberately outside `PinnedDockView`'s scroll area: no amount of scrolling
/// among the pins can move the desk off screen, so the desk and its toggle stay
/// adjacent. Exactly one row — it never expands children, which is what makes
/// "always directly above the toggle" a guarantee rather than a usual case.
///
/// A `List` for a single row looks like ceremony, but `WorktreeRowView` has no
/// tap gesture, so without it the row would render correctly and simply not
/// respond to clicks — and `.onTapGesture` would kill its `.contextMenu`.
struct PinnedDockDeskSlot: View {
    let desk: Worktree?
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let desk {
            List(selection: $appState.selectedWorktreeIDs) {
                WorktreeRowView(worktree: desk)
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .tag(desk.id)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: PinnedDockMetrics.rowHeight)
        }
    }
}
