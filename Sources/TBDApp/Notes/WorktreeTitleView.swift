import SwiftUI
import TBDShared

/// Replaces the static "TBD" window title in the toolbar. Shows the selected
/// worktree's display name (14 pt) followed by its repo name (11 pt, secondary),
/// then a notes button that toggles the repo/worktree notepad popover.
struct WorktreeTitleView: View {
    let worktree: Worktree
    @EnvironmentObject var appState: AppState
    @State private var showNotes = false

    private var repoName: String? {
        worktree.repoID.flatMap { appState.repoName(for: $0) }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(worktree.displayName)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)

            if let repoName {
                Text(repoName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button {
                showNotes.toggle()
            } label: {
                Image(systemName: "note.text")
            }
            .buttonStyle(.borderless)
            .help("Notes")
            .popover(isPresented: $showNotes, arrowEdge: .bottom) {
                NotepadPopoverView(scope: NotesScope.resolve(for: worktree))
            }
        }
    }
}
