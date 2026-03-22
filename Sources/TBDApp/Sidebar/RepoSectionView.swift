import SwiftUI
import TBDShared

struct RepoSectionView: View {
    let repo: Repo
    @EnvironmentObject var appState: AppState

    @State private var isExpanded = true

    var mainWorktree: Worktree? {
        (appState.worktrees[repo.id] ?? [])
            .first { $0.status == .main }
    }

    var worktrees: [Worktree] {
        (appState.worktrees[repo.id] ?? [])
            .filter { $0.status == .active }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let main = mainWorktree {
                WorktreeRowView(worktree: main, isMain: true)
                    .tag(main.id)
            }
            ForEach(worktrees) { worktree in
                WorktreeRowView(worktree: worktree)
                    .tag(worktree.id)
            }
        } label: {
            HStack {
                Label(repo.displayName, systemImage: "folder")
                Spacer()
                Button(action: createWorktree) {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("New worktree")
            }
        }
    }

    private func createWorktree() {
        appState.createWorktree(repoID: repo.id)
    }
}
