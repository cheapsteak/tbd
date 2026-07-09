import SwiftUI
import TBDShared

/// Replaces the static "TBD" window title in the toolbar. Left-to-right:
/// notes button, repo name (11 pt) as a dropdown to the repo's detail tabs, and
/// the worktree display name (14 pt) as a dropdown reusing the sidebar row
/// action menu (Rename, Archive, …).
///
/// `appState`/`worktree`/`repoName` are passed in (not read from the
/// environment) so this view has no `@EnvironmentObject` dependency inside the
/// `.principal` toolbar item — matching the `PRButtonLabel` convention.
struct WorktreeTitleView: View {
    let appState: AppState
    let worktree: Worktree
    let repoName: String?
    @State private var showNotes = false
    @State private var hoveringNotes = false

    private var notesTooltip: String {
        worktree.isScratch ? "Worktree notes" : "Repo notes"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            notesButton
            if repoName != nil {
                repoMenu
            }
            worktreeMenu
        }
    }

    // Repo name → dropdown linking to the repo's detail tabs.
    private var repoMenu: some View {
        Menu {
            if let repoID = worktree.repoID {
                Button("Archived Worktrees") { openRepoTab(repoID, .archived) }
                Button("Default Prompts") { openRepoTab(repoID, .instructions) }
                Button("Hooks & Settings") { openRepoTab(repoID, .settings) }
            }
        } label: {
            Text(repoName ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // Worktree name → dropdown reusing the sidebar row's action menu.
    private var worktreeMenu: some View {
        Menu {
            RowActionMenuItemsView(
                actions: RowActionMenuActions(
                    appState: appState,
                    worktree: worktree,
                    onRename: { appState.editingWorktreeID = worktree.id }
                )
            )
        } label: {
            Text(worktree.displayName)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var notesButton: some View {
        Button {
            showNotes.toggle()
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .buttonStyle(.borderless)
        .onHover { hoveringNotes = $0 }
        .overlay(alignment: .top) {
            if hoveringNotes && !showNotes {
                Text(notesTooltip)
                    .font(.caption)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                    .offset(y: 26)
                    .allowsHitTesting(false)
            }
        }
        .popover(isPresented: $showNotes, arrowEdge: .bottom) {
            NotepadPopoverView(scope: NotesScope.resolve(for: worktree))
        }
    }

    private func openRepoTab(_ repoID: UUID, _ tab: RepoDetailTab) {
        appState.pendingRepoDetailTab = tab
        appState.selectRepo(id: repoID)
    }
}
