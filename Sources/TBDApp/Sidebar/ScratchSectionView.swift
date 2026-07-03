import SwiftUI
import TBDShared

/// Pinned sidebar section for repo-less scratch spaces (`Worktree.isScratch`).
/// Modeled on `RepoSectionView`: a header row with a hover `+` to create a new
/// scratch space, followed by the scratch worktree rows.
struct ScratchSectionView: View {
    @EnvironmentObject var appState: AppState
    @State private var isHeaderHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text("Scratch")
                .font(.headline).foregroundStyle(.secondary)
            Spacer()
            if isHeaderHovered {
                Button { appState.createScratch() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(HoverPressButtonStyle())
                .help("New scratch space")
            }
        }
        .onHover { isHeaderHovered = $0 }
        .listRowInsets(EdgeInsets(top: 0, leading: -2, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)

        ForEach(appState.scratchWorktrees) { wt in
            WorktreeRowView(worktree: wt)   // sectionRepoID nil → no (repo) suffix; repo affordances vanish
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .tag(wt.id)
        }
    }
}
