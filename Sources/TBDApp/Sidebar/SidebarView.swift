import AppKit
import SwiftUI
import TBDShared

struct SidebarView: View {
    @Environment(AppState.self) var appState
    @AppStorage("sidebar.showHiddenRepos") private var showHiddenRepos: Bool = false
    @AppStorage(AppState.showScratchSectionKey) private var showScratchSection: Bool = true
    /// See `AppState.sidebarWorkflowGroupsKey`. Handed to every
    /// `revealSidebarGroups` call as `grouped`, which is the reveal's gate.
    /// Off, the selection reveal is not even computed.
    @AppStorage(AppState.sidebarWorkflowGroupsKey)
    private var workflowGroups: Bool = AppState.sidebarWorkflowGroupsDefault
    /// See `AppState.sidebarCollapseEndedSessionsKey`. With groups off and
    /// this on, an externally selected ended session opens its Ended row.
    @AppStorage(AppState.sidebarCollapseEndedSessionsKey)
    private var collapseEnded: Bool = AppState.sidebarCollapseEndedSessionsDefault
    /// Height of the scrolling repo list, measured by a `.background`
    /// GeometryReader on that list. Feeds `PinnedDockMetrics`' 40% clamp.
    /// Measured on the LIST, never on the dock — reading the dock's own
    /// geometry would feed its height back into its own input.
    @State private var sidebarHeight: CGFloat = 0
    @State private var hasRevealedInitialSelection = false
    /// See `AppState.appKitSidebarKey`. On, the sidebar's list is the native
    /// `NSOutlineView`; off, the SwiftUI `List` below, unchanged.
    @AppStorage(AppState.appKitSidebarKey)
    private var useAppKitSidebar: Bool = AppState.appKitSidebarDefault

    /// What re-evaluates the Ended reveal: a new selection event, or the
    /// option itself turning on.
    private struct EndedRevealKey: Equatable {
        let generation: UInt64
        let selection: RemoteSessionSelection?
    }

    /// Nil, reading nothing observed, unless the option is on and groups are
    /// off, so the default path takes on no new body dependencies.
    private var endedRevealKey: EndedRevealKey? {
        guard !workflowGroups && collapseEnded else { return nil }
        return EndedRevealKey(generation: appState.sidebarSelectionGeneration,
                              selection: appState.selectedRemoteSession)
    }

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
        if useAppKitSidebar {
            nativeSidebar
        } else {
            listSidebar
        }
    }

    /// The native path: the outline fills the column and the shared footer
    /// sits beneath it. The outline controller observes `AppState` itself and
    /// carries its own reveal handling, so none of the `List` path's
    /// `onChange` handlers apply here.
    private var nativeSidebar: some View {
        VStack(spacing: 0) {
            NativeSidebarView()
            VStack(spacing: 0) {
                Divider()
                SidebarFooter()
            }
            .background(.bar)
        }
    }

    @ViewBuilder
    private var listSidebar: some View {
        @Bindable var appState = appState
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
                appState.revealSidebarGroups(
                    appState.sidebarGroupReveal(worktreeIDs: [target], selection: nil), grouped: workflowGroups)
                // Defer to the next runloop tick so a freshly-expanded repo's
                // rows are mounted in the List before we ask to scroll to them.
                DispatchQueue.main.async {
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                    appState.pendingScrollToWorktreeID = nil
                }
            }
            .onChange(of: workflowGroups ? appState.sidebarSelectionReveal : nil, initial: true) { previous, reveal in
                defer { hasRevealedInitialSelection = true }
                guard let reveal else { return }
                appState.revealSidebarGroups(
                    reveal,
                    previous: SidebarReveal.baseline(previous: previous, reveal: reveal,
                                                     hasRevealed: hasRevealedInitialSelection),
                    grouped: workflowGroups)
            }
            .onChange(of: endedRevealKey, initial: true) { _, key in
                guard let key else { return }
                appState.expandedSidebarGroups.formUnion(
                    appState.sidebarEndedRevealGroups(selection: key.selection))
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
            VStack(spacing: 0) {
                // ONE divider, at the very top of the footer group. Verified
                // live: a second Divider() below the dock made it read as part
                // of the scrolling list above instead of part of the footer.
                // Dock and Add Repository share this VStack's
                // `.background(.bar)` as a single visual group.
                Divider()
                PinnedDockView(rows: dockRows, remoteRows: dockRemoteRows,
                               availableHeight: sidebarHeight)
                SidebarFooter()
            }
            .background(.bar)
        }
    }
}
