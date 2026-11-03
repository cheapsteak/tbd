import AppKit
import SwiftUI
import TBDShared

/// The sidebar's footer row: the Add Repository split button and the filter
/// menu, with the clone sheet the split button presents. It is
/// `WindowBottomBarMetrics.height` tall, as the status bar beside it is.
///
/// The filter menu binds `SidebarBuildOptions.showHiddenReposKey`, the key the
/// native outline reads, so flipping it here re-filters the outline.
struct SidebarFooter: View {
    @Environment(AppState.self) var appState
    @AppStorage(SidebarBuildOptions.showHiddenReposKey) private var showHiddenRepos: Bool = false
    @State private var showingClone = false

    /// The spacing between the plus and the menu button. The menu button starts
    /// its text about 7 pt inside its own frame, so a negative spacing brings the
    /// plus's ink to about 5 pt from the "A". The values are measured, so
    /// re-measure if the control changes.
    static let plusGap: CGFloat = -2

    /// How far the plus is lifted. The borderless menu button draws its text
    /// with the capitals' middle 1.5 pt above the bar's centre (measured), and
    /// lifting the plus by this much centres it on the capitals.
    static let plusLift: CGFloat = 1.5

    private var plusImage: some View {
        Group {
            if let plus = SidebarCellKit.symbol("plus", size: 10) {
                Image(nsImage: plus).renderingMode(.template)
            } else {
                Image(systemName: "plus")
            }
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            // A split button: a click on the label opens the folder picker, as it
            // always has; the arrow offers cloning too. The plus sits outside the
            // menu because the borderless menu button places its label's image
            // with its own gap and baseline; it runs the same action as clicking
            // the label, and is the repo header's 10 pt plus.
            HStack(spacing: SidebarFooter.plusGap) {
                Button(action: addRepo) {
                    plusImage
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Add Repository")
                .offset(y: -SidebarFooter.plusLift)
                Menu {
                    Button("Local Folder…", action: addRepo)
                    Button("Clone from URL…") { showingClone = true }
                } label: {
                    Text("Add Repository")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } primaryAction: {
                    addRepo()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
            Spacer()
            filterMenu
        }
        .sheet(isPresented: $showingClone) {
            CloneRepositorySheet()
        }
        .padding(.horizontal, 12)
        // The status bar's height, so the footer lines up with it across the
        // split; the content is centred in it.
        .frame(height: WindowBottomBarMetrics.height)
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
