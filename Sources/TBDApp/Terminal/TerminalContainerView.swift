import SwiftUI
import TBDShared

// MARK: - TerminalContainerView

/// Manages the terminal area for the selected worktree(s).
///
/// - Single worktree selected: Shows TerminalTabBar at top + SplitLayoutView below
///   for the active tab's layout.
/// - Multi-select (Cmd-click): Auto-grid layout, one panel per selected worktree
///   showing its primary terminal. No tab bar.

// MARK: - MainAreaSizeKey

/// Preference key carrying the px size of the actual terminal-rendering area
/// — the SplitLayoutView slot inside SingleWorktreeView, or the grid inside
/// MultiWorktreeView. Excludes the tab bar, divider, dock, and any file
/// panel. AppState reads this via `.onPreferenceChange` to drive the
/// daemon-side resize broadcast so tmux pane dimensions match what SwiftTerm
/// actually renders.
struct MainAreaSizeKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGSize = .zero
    /// Two views in the hierarchy can post this key — SingleWorktreeView's
    /// layoutContent or MultiWorktreeView's grid — but only one is rendered
    /// at a time, so taking the latest value is fine.
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct TerminalContainerView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        // `dockedTerminalIDs` (on AppState) is the single source of truth for
        // which pinned terminals fall to the dock; the keep-alive pager dedups
        // against the same set so a docked terminal is never mounted twice.
        let docked = appState.dockedTerminalIDs
        let dockTerminals = appState.pinnedTerminals.filter { docked.contains($0.id) }

        let activeWorktreeID: UUID? = appState.selectedWorktreeIDs.count == 1
            ? appState.selectedWorktreeIDs.first
            : nil

        let mainContent = Group {
            if appState.selectedWorktreeIDs.count > 1 {
                // Multi-select bypasses keep-alive; existing behavior preserved.
                MultiWorktreeView(worktreeIDs: appState.selectionOrder)
            } else if appState.selectedWorktreeIDs.isEmpty {
                Text("Select a worktree or click + to create one")
                    .foregroundStyle(.secondary)
            } else {
                // Single-select: NSTabViewController-backed pager keeps the recently-
                // visited worktrees' views alive without resetting their @State or
                // leaking AppKit events to inactive subtrees.
                WorktreePager(
                    worktreeIDs: appState.keepAliveWorktreeIDs,
                    activeID: activeWorktreeID
                )
            }
        }
        .onPreferenceChange(MainAreaSizeKey.self) { newSize in
            // The producing GeometryReader lives deeper, in
            // SingleWorktreeView.layoutContent or MultiWorktreeView's grid,
            // so the measurement excludes the tab bar / divider chrome.
            // SwiftUI fires .onPreferenceChange with .zero in some early
            // layout passes; ignore those so we don't broadcast a degenerate
            // size to the daemon.
            guard newSize.width > 0, newSize.height > 0 else { return }
            appState.mainAreaSize = newSize
        }

        // Always render DockSplitView so mainContent stays in the same
        // structural position. Switching between bare `mainContent` and
        // `DockSplitView { mainContent }` destroys all terminal views,
        // killing their tmux sessions. Dock content is still conditionally
        // rendered (cheap to recreate).
        DockSplitView(
            dockRatio: $appState.dockRatio,
            isDockVisible: !dockTerminals.isEmpty,
            mainContent: { mainContent },
            dockContent: { PinnedTerminalDock(terminals: dockTerminals) }
        )
    }
}

// MARK: - SingleWorktreeView

/// Shows the tab bar and split layout for a single selected worktree.
struct SingleWorktreeView: View {
    let worktreeID: UUID
    @EnvironmentObject var appState: AppState

    private var activeTabIndex: Int {
        get { appState.activeTabIndices[worktreeID] ?? 0 }
        nonmutating set {
            appState.setActiveTab(worktreeID: worktreeID, tabIndex: newValue)
            appState.historyActiveWorktrees.remove(worktreeID)
        }
    }

    private var worktree: Worktree? {
        for wts in appState.worktrees.values {
            if let wt = wts.first(where: { $0.id == worktreeID }) {
                return wt
            }
        }
        return nil
    }

    private var worktreeTabs: [Tab] {
        appState.tabs[worktreeID] ?? []
    }

    /// Resolve a tab ID to its terminal ID (nil for non-terminal tabs).
    private func terminalID(for tabID: UUID) -> UUID? {
        guard case .terminal(let id) = appState.tabs[worktreeID]?.first(where: { $0.id == tabID })?.content else {
            return nil
        }
        return id
    }

    var body: some View {
        if let worktree {
            VStack(spacing: 0) {
                // Tab bar — always visible, even with no tabs, so the + menu
                // and history button remain reachable from the empty state.
                TabBar(
                    tabs: worktreeTabs,
                    worktreeID: worktreeID,
                    activeTabIndex: Binding(
                        get: { activeTabIndex },
                        set: { activeTabIndex = $0 }
                    ),
                    onAddShell: {
                        Task {
                            await appState.createTerminal(worktreeID: worktreeID)
                            selectLastTab()
                        }
                    },
                    onAddClaude: {
                        Task {
                            await appState.createClaudeTerminal(worktreeID: worktreeID)
                            selectLastTab()
                        }
                    },
                    onAddClaudeProfile: { profileID in
                        Task {
                            await appState.createClaudeTerminal(
                                worktreeID: worktreeID, profileID: profileID
                            )
                            selectLastTab()
                        }
                    },
                    onAddCodex: {
                        Task {
                            await appState.createCodexTerminal(worktreeID: worktreeID)
                            selectLastTab()
                        }
                    },
                    onAddNote: {
                        Task {
                            await appState.createNote(worktreeID: worktreeID)
                            selectLastTab()
                        }
                    },
                    onCloseTab: { index in
                        closeTab(at: index)
                    },
                    terminalForTab: { tabID in
                        guard let terminalID = terminalID(for: tabID) else { return nil }
                        return appState.terminals[worktreeID]?.first { $0.id == terminalID }
                    },
                    onSuspendTab: { tabID in
                        guard let terminalID = terminalID(for: tabID) else { return }
                        Task {
                            try? await appState.daemonClient.terminalSuspend(terminalID: terminalID)
                            await appState.refreshTerminals(worktreeID: worktreeID)
                        }
                    },
                    onResumeTab: { tabID in
                        guard let terminalID = terminalID(for: tabID) else { return }
                        Task {
                            try? await appState.daemonClient.terminalResume(terminalID: terminalID)
                            await appState.refreshTerminals(worktreeID: worktreeID)
                        }
                    },
                    onForkTab: { tabID in
                        guard let tID = terminalID(for: tabID) else { return }
                        let terminal = appState.terminals[worktreeID]?.first { $0.id == tID }
                        guard let sessionID = terminal?.claudeSessionID else { return }
                        Task {
                            await appState.forkClaudeTerminal(worktreeID: worktreeID, sessionID: sessionID, tokenID: terminal?.profileID)
                            selectLastTab()
                        }
                    },
                    isHistorySelected: appState.historyActiveWorktrees.contains(worktreeID),
                    onHistoryTab: {
                        appState.toggleHistory(worktreeID: worktreeID)
                    }
                )

                Divider()

                // Thin header while a blocking pre-session hook runs and the
                // user is watching it: the worktree is still `.creating`, so
                // explain why no agent terminal exists yet.
                if appState.showsPreSessionBanner(for: worktree) {
                    PreSessionSetupBanner()
                    Divider()
                }

                // Split layout view for the active tab's layout. Publish its
                // measured size to MainAreaSizeKey so the daemon-side tmux
                // resize matches the actual SwiftTerm pane area (tab bar +
                // divider above are excluded).
                layoutContent(worktree: worktree)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: MainAreaSizeKey.self, value: geometry.size)
                    })
            }
            // TmuxBridge sessions are created on-demand by TerminalPanelView
            .task(id: worktreeID) {
                // Auto-create a terminal when selecting a main worktree with none
                let terminals = appState.terminals[worktreeID] ?? []
                if worktree.status == .main && terminals.isEmpty {
                    await appState.createTerminal(worktreeID: worktreeID)
                }
            }
            .task(id: worktreeTabs.isEmpty) {
                // When a non-main worktree has no tabs, populate session
                // history so the empty state can show it. `.main` worktrees
                // auto-create a terminal above and never sit in this state.
                guard worktreeTabs.isEmpty,
                      AppState.shouldPopulateHistoryForEmptyTabs(worktree: worktree) else { return }
                await appState.fetchSessions(worktreeID: worktreeID)
            }
        } else {
            Text("Worktree not found")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func layoutContent(worktree: Worktree) -> some View {
        if appState.historyActiveWorktrees.contains(worktreeID) {
            HistoryPaneView(worktreeID: worktreeID)
        } else if let tab = activeTab {
            let layoutBinding = Binding<LayoutNode>(
                get: { appState.layouts[tab.id] ?? .pane(tab.content) },
                set: { appState.layouts[tab.id] = $0 }
            )

            SplitLayoutView(
                node: layoutBinding.wrappedValue,
                worktree: worktree,
                tabID: tab.id,
                layout: layoutBinding
            )
            .id(tab.id) // Force new view hierarchy when switching tabs
        } else {
            switch (appState.historyLoadStates[worktreeID] ?? .idle).emptyTabsContent {
            case .history:
                HistoryPaneView(worktreeID: worktreeID)
            case .placeholder:
                VStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("No terminals")
                        .foregroundStyle(.secondary)
                    Button("Create Terminal") {
                        Task {
                            await appState.createTerminal(worktreeID: worktreeID)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func selectLastTab() {
        let newCount = appState.tabs[worktreeID]?.count ?? 0
        if newCount > 0 {
            activeTabIndex = newCount - 1
        }
    }

    private var activeTab: Tab? {
        let tabs = worktreeTabs
        guard !tabs.isEmpty else { return nil }
        return tabs[min(activeTabIndex, tabs.count - 1)]
    }

    private func closeTab(at index: Int) {
        appState.closeTab(worktreeID: worktreeID, index: index)
    }
}

// MARK: - PreSessionSetupBanner

/// Slim header bar shown above the terminal while a blocking `preSession`
/// hook is still running (worktree `.creating`, pre-session tab active).
/// Same visual idiom as the proxy-unreachable banner in TerminalPanelView,
/// but informational rather than warning-toned.
private struct PreSessionSetupBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            // Static icon, deliberately not a ProgressView: a spinner forces
            // continuous CoreAnimation commits for the whole hook duration
            // (minutes) for zero information gain — same rationale as the
            // static sidebar status icons (c8769a8).
            Image(systemName: "hammer")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 12, height: 12)
            Text("Pre-session setup running — the agent will start when it completes.")
                .font(.caption)
            Spacer()
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.15))
    }
}

// MARK: - MultiWorktreeView

/// Auto-grid layout showing one panel per selected worktree.
/// Each panel displays the worktree name and its primary terminal.
private struct MultiWorktreeView: View {
    let worktreeIDs: [UUID]
    @EnvironmentObject var appState: AppState

    private var columns: Int {
        let count = worktreeIDs.count
        if count <= 1 { return 1 }
        if count <= 4 { return 2 }
        if count <= 9 { return 3 }
        return 4
    }

    var body: some View {
        GeometryReader { geometry in
            let cols = columns
            let rows = Int(ceil(Double(worktreeIDs.count) / Double(cols)))
            let cellWidth = geometry.size.width / CGFloat(cols)
            let cellHeight = geometry.size.height / CGFloat(rows)

            VStack(spacing: 1) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 1) {
                        ForEach(0..<cols, id: \.self) { col in
                            let index = row * cols + col
                            if index < worktreeIDs.count {
                                MultiWorktreeCell(
                                    worktreeID: worktreeIDs[index],
                                    isPrimary: index == 0
                                )
                                .frame(width: cellWidth - 1, height: cellHeight - 1)
                            } else {
                                Color.clear
                                    .frame(width: cellWidth - 1, height: cellHeight - 1)
                            }
                        }
                    }
                }
            }
            .background(Color(nsColor: .separatorColor))
            // The first cell publishes its inner-content size to
            // MainAreaSizeKey from inside MultiWorktreeCell — measuring there
            // excludes the per-cell header bar (~21pt) and divider, which
            // the previous outer-grid measurement included. All cells are
            // equal size so one publisher suffices.
        }
    }
}

// MARK: - MultiWorktreeCell

/// A single cell in the multi-worktree grid showing worktree name and its primary terminal.
private struct MultiWorktreeCell: View {
    let worktreeID: UUID
    /// First cell in the grid publishes its inner-content size to
    /// MainAreaSizeKey so the daemon-side tmux resize matches the actual
    /// SwiftTerm pane area (excludes the per-cell header bar + divider).
    /// All cells are equal size so a single publisher suffices.
    let isPrimary: Bool
    @EnvironmentObject var appState: AppState

    private var worktree: Worktree? {
        for wts in appState.worktrees.values {
            if let wt = wts.first(where: { $0.id == worktreeID }) {
                return wt
            }
        }
        return nil
    }

    /// The terminal shown in this cell — derived from the active tab's layout
    /// so it stays consistent with the dock's visibleTerminalIDs filter.
    private var primaryTerminal: Terminal? {
        let tabs = appState.tabs[worktreeID] ?? []
        guard !tabs.isEmpty else { return appState.terminals[worktreeID]?.first }
        let activeIndex = appState.activeTabIndices[worktreeID] ?? 0
        let tab = tabs[min(activeIndex, tabs.count - 1)]
        let layout = appState.layouts[tab.id] ?? .pane(tab.content)
        // Use the first terminal in the active tab's layout tree
        guard let firstID = layout.allTerminalIDs().first else {
            return appState.terminals[worktreeID]?.first
        }
        return appState.terminals[worktreeID]?.first { $0.id == firstID }
    }

    private var activeTab: Tab? {
        let tabs = appState.tabs[worktreeID] ?? []
        guard !tabs.isEmpty else { return nil }
        let activeIndex = appState.activeTabIndices[worktreeID] ?? 0
        return tabs[min(activeIndex, tabs.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with worktree name
            HStack {
                if let worktree {
                    Text(worktree.displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(worktree.branch)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Terminal placeholder content. The GeometryReader below
            // (only attached on the primary cell) measures this slot
            // specifically — excluding the header HStack and divider above
            // — so MainAreaSizeKey reflects the actual SwiftTerm rendering
            // area, not the full grid cell.
            terminalContent
                .background(
                    Group {
                        if isPrimary {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: MainAreaSizeKey.self,
                                    value: geometry.size
                                )
                            }
                        }
                    }
                )
        }
    }

    @ViewBuilder
    private var terminalContent: some View {
        if let worktree, let terminal = primaryTerminal {
            let layoutBinding = Binding<LayoutNode>(
                get: {
                    appState.layouts[worktreeID]
                        ?? .pane(.terminal(terminalID: terminal.id))
                },
                set: { newLayout in
                    appState.layouts[worktreeID] = newLayout
                }
            )
            PanePlaceholder(
                content: .terminal(terminalID: terminal.id),
                worktree: worktree,
                tabID: activeTab?.id,
                layout: layoutBinding
            )
        } else {
            ZStack {
                Color(nsColor: .textBackgroundColor)
                VStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No terminal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - DockSplitView

/// A horizontal split between main content (left) and pinned terminal dock (right).
/// Uses deferred resize: shows an indicator line during drag, only commits on release.
private struct DockSplitView<Main: View, Dock: View>: View {
    @Binding var dockRatio: CGFloat
    let isDockVisible: Bool
    @ViewBuilder let mainContent: () -> Main
    @ViewBuilder let dockContent: () -> Dock

    @State private var dragStartRatio: CGFloat?
    /// Preview ratio shown as indicator line during drag; nil when not dragging.
    @State private var previewRatio: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let dividerWidth: CGFloat = isDockVisible ? 4 : 0
            let available = totalWidth - dividerWidth
            let dockWidth = isDockVisible ? available * dockRatio : 0
            let mainWidth = available - dockWidth

            HStack(spacing: 0) {
                mainContent()
                    .frame(width: mainWidth)

                if isDockVisible {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: dividerWidth)
                        .contentShape(Rectangle())
                        .cursor(.resizeLeftRight)
                        .overlay {
                            if let preview = previewRatio {
                                let offsetX = -(preview - dockRatio) * available
                                Rectangle()
                                    .fill(Color.accentColor.opacity(0.6))
                                    .frame(width: 2)
                                    .offset(x: offsetX)
                                    .allowsHitTesting(false)
                            }
                        }
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    if dragStartRatio == nil {
                                        dragStartRatio = dockRatio
                                    }
                                    guard let startRatio = dragStartRatio, available > 0 else { return }
                                    let delta = -value.translation.width / available
                                    previewRatio = max(0.1, min(0.6, startRatio + delta))
                                }
                                .onEnded { _ in
                                    if let preview = previewRatio {
                                        dockRatio = preview
                                    }
                                    previewRatio = nil
                                    dragStartRatio = nil
                                }
                        )

                    dockContent()
                        .frame(width: dockWidth)
                }
            }
        }
    }
}
