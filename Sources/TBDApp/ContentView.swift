import AppKit
import SwiftUI
import TBDShared

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
            } detail: {
                if !appState.isConnected {
                    disconnectedView
                } else if appState.repos.isEmpty {
                    emptyStateView
                } else if appState.selectedWorktreeIDs.isEmpty {
                    Text("Select a worktree or click + to create one")
                        .foregroundStyle(.secondary)
                } else {
                    TerminalContainerView()
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: addRepo) {
                        Label("Add Repository", systemImage: "plus.rectangle.on.folder")
                    }
                    .help("Add a Git repository")

                    Picker("Filter", selection: $appState.repoFilter) {
                        Text("All Repos").tag(UUID?.none)
                        Divider()
                        ForEach(appState.repos) { repo in
                            Text(repo.displayName).tag(UUID?.some(repo.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .help("Filter sidebar by repository")
                }
            }

            StatusBarView()
        }
        .onChange(of: appState.selectedWorktreeIDs) { _, newSelection in
            markSelectedWorktreesAsRead(newSelection)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No Repositories")
                .font(.title2)
                .fontWeight(.medium)

            Text("Add a Git repository to get started.\nTBD will manage worktrees and terminals for each repo.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)

            Button(action: addRepo) {
                Label("Add Repository", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Disconnected State

    private var disconnectedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 48))
                .foregroundStyle(.red.opacity(0.6))

            Text("Daemon Not Connected")
                .font(.title2)
                .fontWeight(.medium)

            Text("The TBD daemon is not running or could not be reached.\nThe app will attempt to reconnect automatically.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)

            Button("Retry Connection") {
                Task {
                    await appState.connectAndLoadInitialState()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

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

    private func markSelectedWorktreesAsRead(_ selection: Set<UUID>) {
        for worktreeID in selection {
            appState.notifications[worktreeID] = nil
            Task {
                await appState.markNotificationsRead(worktreeID: worktreeID)
            }
        }
    }
}
