import os
import SwiftUI
import TBDShared

private let subtreeLogger = Logger(subsystem: "com.tbd.app", category: "sidebar-subtree")

/// Hard recursion cap to defend against a cyclic `parentWorktreeID` chain in
/// the DB (e.g. introduced by a manual `sqlite3` edit that slipped past
/// `WorktreeStore.nullOrphanedParents()`'s cycle pass). Without this guard,
/// `WorktreeSubtreeView` would stack-overflow on any cyclic graph.
private let kMaxSubtreeDepth = 50

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

        if depth < kMaxSubtreeDepth {
            ForEach(appState.children(of: worktree.id)) { child in
                WorktreeSubtreeView(
                    worktree: child,
                    depth: depth + 1,
                    sectionRepoID: sectionRepoID
                )
            }
        } else {
            // Cap hit. Almost certainly a cyclic parent chain in the DB.
            // Log once per cap-hit row so a future incident is debuggable.
            Color.clear
                .frame(height: 0)
                .onAppear {
                    subtreeLogger.error("WorktreeSubtreeView depth cap (\(kMaxSubtreeDepth, privacy: .public)) hit at worktree \(worktree.id, privacy: .public); suspect cyclic parentWorktreeID chain")
                }
        }
    }
}
