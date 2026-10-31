import AppKit
import SwiftUI
import TBDShared

/// The sidebar's footer row: the Add Repository split button and the filter
/// menu, with the clone sheet the split button presents. Shared by both
/// sidebar paths, so the SwiftUI `List` and the native outline offer the same
/// footer.
///
/// The filter menu binds `SidebarBuildOptions.showHiddenReposKey`, the key
/// `SidebarView` and the native outline read, so flipping it here re-filters
/// whichever list is showing.
struct SidebarFooter: View {
    @Environment(AppState.self) var appState
    @AppStorage(SidebarBuildOptions.showHiddenReposKey) private var showHiddenRepos: Bool = false
    @State private var showingClone = false

    var body: some View {
        HStack(spacing: 4) {
            // A split button: a click on the label opens the folder
            // picker, as it always has; the arrow offers cloning too.
            Menu {
                Button("Local Folder…", action: addRepo)
                Button("Clone from URL…") { showingClone = true }
            } label: {
                Label("Add Repository", systemImage: "plus.rectangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } primaryAction: {
                addRepo()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)
            Spacer()
            filterMenu
        }
        .sheet(isPresented: $showingClone) {
            CloneRepositorySheet()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
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
