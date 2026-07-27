import AppKit
import SwiftUI
import TBDShared

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("sidebar.showHiddenRepos") private var showHiddenRepos: Bool = false
    @AppStorage(AppState.showScratchSectionKey) private var showScratchSection: Bool = true
    @AppStorage(AppState.nightwatchExperimentalKey) private var nightwatchExperimental: Bool = false
    /// Height of the scrolling repo list, measured by a `.background`
    /// GeometryReader on that list. Feeds `PinnedDockMetrics`' 40% clamp.
    /// Measured on the LIST, never on the dock — reading the dock's own
    /// geometry would feed its height back into its own input.
    @State private var sidebarHeight: CGFloat = 0

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
                if AppState.scratchSectionVisible(setting: showScratchSection, spaces: appState.scratchWorktrees) {
                    ScratchSectionView()
                }
                ForEach(filteredRepos) { repo in
                    RepoSectionView(repo: repo)
                        .opacity(repo.hidden ? 0.55 : 1.0)
                }
                // Rendered below the repos, not above: remoteness shouldn't
                // be positionally focal. Hidden entirely when no provider is
                // registered.
                if AppState.remoteSectionVisible(providers: appState.remoteProviders) {
                    RemoteSectionView()
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
            .overlayPreferenceValue(RowTooltipPreferenceKey.self) { pref in
                GeometryReader { geo in
                    if let pref {
                        let rect = geo[pref.anchor]
                        RowTooltipBubble(text: pref.text)
                            .offset(x: rect.minX, y: rect.maxY + 4)
                    }
                }
                .allowsHitTesting(false)
            }
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { sidebarHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in sidebarHeight = h }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 26)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            let dockRows = PinnedDockContent.rows(
                allWorktrees: appState.allWorktrees,
                selectedIDs: appState.selectedWorktreeIDs,
                children: appState.children(of:)
            )
            let dockRemoteRows = PinnedDockContent.remoteRows(
                allRemoteSessions: appState.remoteSessions
            )
            let desk = PinnedDockContent.deskRow(
                allWorktrees: appState.allWorktrees,
                mode: appState.nightwatchMode,
                experimentalEnabled: nightwatchExperimental
            )
            VStack(spacing: 0) {
                // ONE divider, at the very top of the footer group. Verified
                // live: a second Divider() below the dock made it read as part
                // of the scrolling list above instead of part of the footer.
                // Dock, desk slot, mode toggle and Add Repository share this
                // VStack's `.background(.bar)` as a single visual group.
                Divider()
                PinnedDockView(rows: dockRows, remoteRows: dockRemoteRows,
                               availableHeight: sidebarHeight)
                PinnedDockDeskSlot(desk: desk)
                if nightwatchExperimental {
                    NightwatchModeToggle()
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                }
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
                .padding(.top, nightwatchExperimental ? 0 : 8)
                .padding(.bottom, 8)
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
