import os
import SwiftUI
import TBDShared

private let subtreeLogger = Logger(subsystem: "com.tbd.app", category: "sidebar-subtree")

/// Hard recursion cap to defend against a cyclic `parentWorktreeID` chain in
/// the DB (e.g. introduced by a manual `sqlite3` edit that slipped past
/// `WorktreeStore.breakCyclicParents()` at daemon startup). Without this
/// guard, `WorktreeSubtreeView` would stack-overflow on any cyclic graph.
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
    @Environment(AppState.self) var appState
    /// Read only to place the row: the project chevron's position decides
    /// which column every section title sits in, and rows follow their title.
    /// See `SidebarHeaderMetrics.childRowLeadingInset`.
    @AppStorage(AppState.chevronBeforeProjectNameKey)
    private var chevronBeforeProjectName: Bool = AppState.chevronBeforeProjectNameDefault

    var body: some View {
        WorktreeRowView(
            worktree: worktree,
            indentLevel: depth,
            sectionRepoID: sectionRepoID
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.0001))
        .listRowInsets(EdgeInsets(
            top: 0,
            leading: SidebarHeaderMetrics.childRowLeadingInset(
                chevronBeforeProjectName: chevronBeforeProjectName),
            bottom: 0,
            trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .tag(worktree.id)

        if depth < kMaxSubtreeDepth {
            groupedChildren
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

    /// `depth` counts worktree ancestry only. Each disclosure adds visual
    /// padding around its rows without consuming the structural recursion cap.
    @ViewBuilder
    private var groupedChildren: some View {
        let groups = appState.sidebarRemoteGroups(parentID: worktree.id)
        childRows(groups.localRoots, groupInset: 0)
        if !groups.isEmpty {
            let remoteID = SidebarGroupID(owner: .parent(worktree.id), kind: .remote)
            let exitedID = SidebarGroupID(owner: .parent(worktree.id), kind: .exited)
            groupHeader(remoteID, title: "Remote", summary: groups.summary, groupInset: 0)
            if appState.expandedSidebarGroups.contains(remoteID) {
                childRows(groups.remoteRoots, groupInset: 1)
                if groups.hasExited {
                    groupHeader(exitedID, title: "Exited", summary: groups.exitedSummary, groupInset: 1)
                    if appState.expandedSidebarGroups.contains(exitedID) {
                        childRows(groups.exitedRoots, groupInset: 2)
                    }
                }
            }
        }
    }

    private func childRows(_ rows: [Worktree], groupInset: Int) -> some View {
        ForEach(rows) { child in
            WorktreeSubtreeView(worktree: child, depth: depth + 1, sectionRepoID: sectionRepoID)
                .padding(.leading, CGFloat(groupInset) * 16)
        }
    }

    private func groupHeader(_ id: SidebarGroupID, title: String,
                             summary: SidebarRemoteGroups.Summary, groupInset: Int) -> some View {
        SidebarGroupHeader(id: id, title: title, summary: summary)
            .padding(.leading, CGFloat(depth + 1 + groupInset) * 16)
            .listRowInsets(EdgeInsets(
                top: 0, leading: SidebarHeaderMetrics.childRowLeadingInset(
                    chevronBeforeProjectName: chevronBeforeProjectName), bottom: 0, trailing: 0))
    }

}
