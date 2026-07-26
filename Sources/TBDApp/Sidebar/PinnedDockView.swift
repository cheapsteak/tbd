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

    /// The pinned roots, in display order — the elements `.onMove` addresses.
    private var roots: [PinnedDockRow] {
        rows.filter { $0.depth == 0 }
    }

    /// One root's expanded descendants: its contiguous run of rows minus the
    /// root itself, which `body` emits directly.
    private func descendants(of root: PinnedDockRow) -> [PinnedDockRow] {
        Array(PinnedDockContent.subtree(of: root.worktree.id, in: rows).dropFirst())
    }

    @ViewBuilder
    private func dockRow(_ row: PinnedDockRow) -> some View {
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

    var body: some View {
        if !rows.isEmpty {
            ScrollViewReader { proxy in
                List(selection: $appState.selectedWorktreeIDs) {
                    // Nested deliberately: `.onMove` hands back indices into its
                    // OWN ForEach's elements, so the outer ForEach must iterate
                    // pinned ROOTS. A flat ForEach over `rows` would move the
                    // wrong worktree whenever a subtree was expanded, because
                    // the indices would address the flattened list. This mirrors
                    // RepoSectionView, whose ForEach iterates top-level
                    // worktrees while WorktreeSubtreeView emits many rows each.
                    ForEach(roots) { root in
                        // The root row is emitted DIRECTLY, not through a
                        // nested ForEach, and the descendants follow in one of
                        // their own — exactly WorktreeSubtreeView's shape.
                        // Verified live: wrapping the root in a ForEach too
                        // makes the outer element's content a bare ForEach, and
                        // AppKit then never starts a drag session, so `.onMove`
                        // silently never fires.
                        dockRow(root)
                        ForEach(descendants(of: root)) { row in
                            dockRow(row)
                        }
                    }
                    .onMove { source, destination in
                        appState.reorderPins(fromOffsets: source, toOffset: destination)
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
