import AppKit
import SwiftUI
import TBDShared

private struct HoverPressButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isPressed
                          ? Color.primary.opacity(0.15)
                          : isHovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .padding(6)
            .contentShape(Rectangle())
            .padding(-6)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

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
            .filter { $0.status == .active || $0.status == .creating }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: { isExpanded.toggle() }) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(HoverPressButtonStyle())
            .help(isExpanded ? "Collapse" : "Expand")

            Text(repo.displayName)
                .font(.headline)
                .foregroundStyle(
                    repo.status == .missing
                        ? AnyShapeStyle(Color.secondary.opacity(0.5))
                        : AnyShapeStyle(appState.selectedRepoID == repo.id ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
                )

            if repo.status == .missing {
                Text("[missing]")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.7))
                Button("Locate…") {
                    locateRepo()
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            Spacer()

            Button(action: createWorktree) {
                Image(systemName: "plus")
                    .font(.caption)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(HoverPressButtonStyle())
            .help("New worktree")
            .disabled(repo.status == .missing)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectRepo(id: repo.id)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .tag(repo.id)

        if isExpanded {
            if let main = mainWorktree {
                WorktreeRowView(worktree: main, isMain: true)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
                    .tag(main.id)
            }
            ForEach(worktrees) { worktree in
                WorktreeRowView(worktree: worktree)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
                    .tag(worktree.id)
            }
            .onMove { source, destination in
                appState.reorderWorktrees(repoID: repo.id, fromOffsets: source, toOffset: destination)
            }
        }
    }

    private func createWorktree() {
        appState.createWorktree(repoID: repo.id)
    }

    private func locateRepo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the new location of \(repo.displayName)"
        panel.prompt = "Relocate"
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await appState.relocateRepo(id: repo.id, newPath: url.path)
            }
        }
    }
}
