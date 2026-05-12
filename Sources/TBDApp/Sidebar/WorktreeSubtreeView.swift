import SwiftUI
import TBDShared

/// Renders a worktree row plus its descendants, recursively.
///
/// Children render directly under their parent within the parent's repo section,
/// indented further. A child whose `repoID` differs from the section's repo gets
/// a muted `(repo-name)` suffix in the row label (handled in `WorktreeRowView`).
struct WorktreeSubtreeView: View {
    let worktree: Worktree
    let depth: Int
    let sectionRepoID: UUID
    @EnvironmentObject var appState: AppState

    var body: some View {
        WorktreeRowView(
            worktree: worktree,
            indentLevel: depth,
            sectionRepoID: sectionRepoID
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.0001))
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .tag(worktree.id)

        ForEach(appState.children(of: worktree.id)) { child in
            WorktreeSubtreeView(
                worktree: child,
                depth: depth + 1,
                sectionRepoID: sectionRepoID
            )
        }
    }
}
