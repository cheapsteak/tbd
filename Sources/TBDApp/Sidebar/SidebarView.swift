import AppKit
import SwiftUI
import TBDShared

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("sidebar.showHiddenRepos") private var showHiddenRepos: Bool = false

    var filteredRepos: [Repo] {
        let base: [Repo]
        if let filterID = appState.repoFilter {
            base = appState.repos.filter { $0.id == filterID }
        } else {
            base = appState.repos
        }
        return showHiddenRepos ? base : base.filter { !$0.hidden }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $appState.selectedWorktreeIDs) {
                ForEach(filteredRepos) { repo in
                    RepoSectionView(repo: repo)
                        .opacity(repo.hidden ? 0.55 : 1.0)
                }
            }
            .onChange(of: appState.pendingScrollToWorktreeID) { _, target in
                guard let target else { return }
                // Defer to the next runloop tick so a freshly-expanded repo's
                // rows are mounted in the List before we ask to scroll to them.
                DispatchQueue.main.async {
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                    appState.pendingScrollToWorktreeID = nil
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 26)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 4) {
                    Button(action: addRepo) {
                        Label("Add Repository", systemImage: "plus.rectangle")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    Spacer()
                    filterMenu
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }

    private var hiddenCount: Int {
        appState.repos.filter { $0.hidden }.count
    }

    private var filterMenu: some View {
        Menu {
            Toggle(isOn: $showHiddenRepos) {
                if hiddenCount > 0 {
                    Text("Show hidden repos (\(hiddenCount))")
                } else {
                    Text("Show hidden repos")
                }
            }
        } label: {
            Image(systemName: showHiddenRepos
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter")
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
