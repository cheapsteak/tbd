import SwiftUI
import TBDShared

/// The scrolling pinned area of the sidebar dock.
///
/// A second `List` bound to the same selection set as the sidebar's main list is
/// what makes these rows clickable: `WorktreeRowView` carries no tap gesture of
/// its own, so selection happens entirely through `.tag(worktree.id)`. The
/// highlight is NOT what the List provides — the row paints its own, keyed on
/// `appState.selectedWorktreeIDs`, which is why selecting in either place lights
/// up both copies. Reaching for a `VStack` plus `.onTapGesture` instead would
/// silently kill the rows' `.contextMenu`, which macOS suppresses when a tap
/// gesture is attached.
struct PinnedDockView: View {
    let rows: [PinnedDockRow]
    let availableHeight: CGFloat
    @EnvironmentObject var appState: AppState

    var body: some View {
        if !rows.isEmpty {
            ScrollViewReader { proxy in
                List(selection: $appState.selectedWorktreeIDs) {
                    ForEach(rows) { row in
                        WorktreeRowView(
                            worktree: row.worktree,
                            indentLevel: row.depth,
                            sectionRepoID: row.sectionRepoID
                        )
                        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .tag(row.worktree.id)
                    }
                }
                .onChange(of: appState.selectedWorktreeIDs) { _, ids in
                    // Expanding a subtree can push the dock past its cap; keep
                    // the selected row visible rather than scrolled out of view.
                    if let target = ids.first, rows.contains(where: { $0.id == target }) {
                        withAnimation { proxy.scrollTo(target) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: PinnedDockMetrics.height(rowCount: rows.count,
                                                   availableHeight: availableHeight))
        }
    }
}
