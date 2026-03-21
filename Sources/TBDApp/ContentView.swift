import SwiftUI
import TBDShared

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
            } detail: {
                if appState.selectedWorktreeIDs.isEmpty {
                    Text("Select a worktree or click + to create one")
                        .foregroundStyle(.secondary)
                } else {
                    TerminalContainerView()
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    // Add Repo button, Filter, Settings
                }
            }

            StatusBarView()
        }
    }
}
