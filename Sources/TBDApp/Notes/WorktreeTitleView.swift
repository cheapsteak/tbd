import SwiftUI
import TBDShared

/// Replaces the static "TBD" window title in the toolbar. Shows the selected
/// worktree's display name (14 pt) followed by its repo name (11 pt, secondary),
/// then a notes button that toggles the repo/worktree notepad popover.
///
/// `repoName` is passed in (not read from the environment) so this view has no
/// `@EnvironmentObject` dependency inside the `.principal` toolbar item —
/// matching the `PRButtonLabel` convention for toolbar-hosted views.
struct WorktreeTitleView: View {
    let worktree: Worktree
    let repoName: String?
    @State private var showNotes = false

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
