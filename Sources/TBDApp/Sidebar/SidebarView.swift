import AppKit
import SwiftUI
import TBDShared

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var filteredRepos: [Repo] {
        if let filterID = appState.repoFilter {
            return appState.repos.filter { $0.id == filterID }
        }
        return appState.repos
    }

    var body: some View {
        List(selection: $appState.selectedWorktreeIDs) {
            ForEach(filteredRepos) { repo in
                RepoSectionView(repo: repo)
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: addRepo) {
                    Label("Add Repository", systemImage: "plus.rectangle")
                }
            }
            ToolbarItem(placement: .automatic) {
                Picker("Filter", selection: $appState.repoFilter) {
                    Text("All Repos").tag(UUID?.none)
                    Divider()
                    ForEach(appState.repos) { repo in
                        Text(repo.displayName).tag(UUID?.some(repo.id))
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private func addRepo() {
        let panel = NSOpenPanel()
        panel.title = "Select a Git Repository"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await appState.addRepo(path: url.path)
            }
        }
    }
}
