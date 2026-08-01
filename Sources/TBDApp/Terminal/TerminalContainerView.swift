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
    /// Spawn-time account picker (AccountPickerSheet). Opened by the plain
    /// "Claude" action (unless "Use default without asking" is on) and by the
    /// "+"-menu "Choose account…" item.
    @State private var showAccountPicker = false

    private var activeTabIndex: Int {
        get { appState.resolvedActiveTabIndex(worktreeID: worktreeID) }
        nonmutating set {
            appState.setActiveTab(worktreeID: worktreeID, tabIndex: newValue)
            appState.historyActiveWorktrees.remove(worktreeID)
        }
    }

    private var worktree: Worktree? {
        // Routes through findWorktree so scratch spaces (which live in
        // `scratchWorktrees`, not the repo-grouped `worktrees` dict) resolve
        // too — otherwise selecting a scratch space shows "Worktree not found".
        appState.findWorktree(id: worktreeID)
    }

    private var worktreeTabs: [TBDShared.Tab] {
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
                        // "I get the data and I pick": plain Claude opens the
                        // account picker unless the user opted out.
                        if appState.skipAccountPicker {
                            Task {
                                await appState.createClaudeTerminal(worktreeID: worktreeID)
                                selectLastTab()
                            }
                        } else {
                            showAccountPicker = true
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
                    onChooseAccount: { showAccountPicker = true },
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
                    // Tab-level suspend/resume and fork closures are gone:
                    // park is a row-level action, and fork moved to the
                    // in-menu "Fork Session" profile picker (#361).
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
                // divider above and the resume banner below are excluded).
                layoutContent(worktree: LocalWorktree(worktree))
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: MainAreaSizeKey.self, value: geometry.size)
                    })

                // Thin footer for the active tab's LIVE terminal (decision in
                // HibernatedBannerModel.banner(for:)):
                // - Scheduled auto-resume: the wide "⏳ resumes ..." text that
                //   used to live in the tab label (inflating tab width), shown
                //   here once per active tab instead of per background tab.
                // - Parked (hibernated / legacy-suspended): NO footer at all —
                //   the hibernate notice is composed INTO the frozen
                //   snapshot's last rows at feed time (see
                //   ParkedSnapshotComposer), which also wins
                //   over scheduled-resume: a parked session's "TBD types
                //   continue at ..." text would be misleading because nothing
                //   is running to receive it.
                let footer = HibernatedBannerModel.banner(for: activeTabTerminal)
                switch footer {
                case .scheduledResume(let resumeAt, let terminalID)?:
                    Divider()
                    ScheduledResumeBanner(resumeAt: resumeAt) {
                        // Same path as the tab context menu's "Cancel
                        // Scheduled Resume" (TabBar), which stays as the
                        // secondary affordance.
                        Task { await appState.cancelScheduledResume(terminalID: terminalID) }
                    }
                case .hibernatedOverlay?, nil:
                    EmptyView()
                }

                // Same slot, same promise as the auto-resume footer: TBD is
                // going to type something into this pane, and here is what.
                // Without it the operator watches an idle agent through the
                // whole wait — which can be a `preSession` hook long — with
                // nothing saying their message is coming.
                if QueuedPromptBannerModel.shows(
                    phase: appState.parkedPrompt(for: worktree)?.phase, footer: footer) {
                    Divider()
                    QueuedPromptBanner(worktree: worktree)
                }
            }
            .sheet(isPresented: $showAccountPicker) {
                AccountPickerSheet { profileID in
                    Task {
                        await appState.createClaudeTerminal(
                            worktreeID: worktreeID, profileID: profileID
                        )
                        selectLastTab()
                    }
                }
                .environmentObject(appState)
            }
            // TmuxBridge sessions are created on-demand by TerminalPanelView
            .task(id: worktreeID) {
                // Auto-create a terminal when selecting a main worktree with none
                let terminals = appState.terminals[worktreeID] ?? []
                if worktree.status == .main && terminals.isEmpty {
                    await appState.createTerminal(worktreeID: worktreeID)
                }
            }
            // Phase 3b: seed the daemon panel-surface mirror for this
            // worktree — nothing else calls `panel.get` for rendering. Keyed
            // on the effective switch AND the connection so it re-runs when
            // capabilities land (flipping the switch false → true) and again
            // after a reconnect, when the daemon may have moved on while the
            // app was away. Inert with the flag off: the guard skips it and
            // `loadPanelSurface` would refuse to fetch anyway.
            .task(id: PanelSurfaceLoadKey(
                worktreeID: worktreeID,
                active: appState.daemonManagedPanelsActive,
                connected: appState.isConnected
            )) {
                guard appState.daemonManagedPanelsActive, appState.isConnected else { return }
                await appState.loadPanelSurface(worktreeID: worktreeID)
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

    /// Panes root a terminal's working directory at the checkout, so the split
    /// layout takes the proven-local wrapper. A selection with no directory on
    /// this disk — the optimistic `.creating` placeholder, which writes
    /// `path: ""` — has no tabs either, so it falls through to the same empty
    /// state it always did.
    @ViewBuilder
    private func layoutContent(worktree: LocalWorktree?) -> some View {
        if appState.historyActiveWorktrees.contains(worktreeID) {
            HistoryPaneView(worktreeID: worktreeID)
        } else if let tab = activeTab, let worktree {
            // Phase 3b: with `enableDaemonManagedPanels` on AND a surface
            // actually mirrored for this tab, render from the daemon. The
            // mirror starts empty and fills asynchronously (the
            // `PanelSurfaceLoadKey` task on the body above), so "flag on,
            // nothing loaded yet" deliberately falls through to the legacy
            // path rather than flashing blank.
            switch appState.workspaceRenderPath(worktreeID: worktree.id, tabID: tab.id) {
            case .daemonSurface(let surface):
                PanelSurfaceWorkspaceView(surface: surface, worktree: worktree)
                    .id(tab.id) // Force new view hierarchy when switching tabs
            case .legacy:
                let layoutBinding = Binding<LayoutNode>(
                    get: { appState.layouts[tab.id] ?? .pane(tab.content) },
                    set: { appState.layouts[tab.id] = $0 }
                )

                SplitLayoutView(
                    node: layoutBinding.wrappedValue,
                    worktree: worktree,
                    tabID: tab.id,
                    actions: .legacy(
                        layout: layoutBinding,
                        appState: appState,
                        worktreeID: worktree.id
                    )
                )
                .id(tab.id) // Force new view hierarchy when switching tabs
            }
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

    private var activeTab: TBDShared.Tab? {
        appState.resolvedActiveTab(worktreeID: worktreeID)
    }

    /// The active tab's terminal, if any — used to decide whether to show
    /// the scheduled-resume banner. Resolved the same way TabBar resolves
    /// each tab's terminal via `terminalForTab`.
    private var activeTabTerminal: Terminal? {
        guard let tabID = activeTab?.id, let terminalID = terminalID(for: tabID) else { return nil }
        return appState.terminals[worktreeID]?.first { $0.id == terminalID }
    }

    private func closeTab(at index: Int) {
        appState.closeTab(worktreeID: worktreeID, index: index)
    }
}

// MARK: - HibernatedBannerModel

/// Pure decision behind the pane's bottom edge: which presentation (if any)
/// the active tab's terminal gets, and the exact hibernated phrasing per
/// `hibernateReason`. Extracted from the view so each branch — including the
/// parked-beats-scheduled precedence — is unit-testable without SwiftUI (same
/// pattern as `TabParkMenuModel` / `terminalIDToWakeOnFocus`).
enum HibernatedBannerModel {
    enum Banner: Equatable {
        /// Terminal is parked (hibernated or legacy-suspended) → the footer
        /// slot stays EMPTY; the hibernate notice is composed into the frozen
        /// snapshot's last rows instead (see `ParkedSnapshotComposer` and the
        /// `parkedNoticeMessage` wiring in PanePlaceholder), carrying this
        /// reason-phrased message.
        case hibernatedOverlay(message: String)
        /// Terminal has a scheduled auto-resume → the "⏳ resumes ..." footer,
        /// which carries an inline Cancel button acting on `cancelTerminalID`
        /// (the same `AppState.cancelScheduledResume` the tab context menu
        /// calls).
        case scheduledResume(at: Date, cancelTerminalID: UUID)

        /// The terminal an inline Cancel button acts on, or nil for banner
        /// states that expose no cancel affordance. Only the scheduled-resume
        /// footer has something to cancel: a parked terminal gets no footer at
        /// all, and its `pendingResumeAt` (if a stale mirror still carries one)
        /// is already cancelled daemon-side by parking.
        var cancelTerminalID: UUID? {
            switch self {
            case .scheduledResume(_, let terminalID): return terminalID
            case .hibernatedOverlay: return nil
            }
        }
    }

    /// nil = neither footer nor overlay strip. Precedence: a parked terminal
    /// gets ONLY the hibernated overlay even when `pendingResumeAt` is also
    /// set (a stale mirror is possible in the delta-to-refetch window even
    /// though parking now cancels the scheduled resume): the scheduled text
    /// promises TBD will type "continue", but nothing is running in a parked
    /// session to receive it.
    static func banner(for terminal: Terminal?) -> Banner? {
        guard let terminal else { return nil }
        if terminal.isParked {
            return .hibernatedOverlay(message: message(for: terminal.hibernateReason))
        }
        if let resumeAt = terminal.pendingResumeAt {
            return .scheduledResume(at: resumeAt, cancelTerminalID: terminal.id)
        }
        return nil
    }

    /// One-line phrasing per park reason. nil (legacy pre-v46 rows) reads the
    /// same as `.auto` — the reason the migration can't attribute is almost
    /// always the idle sweep.
    static func message(for reason: HibernateReason?) -> String {
        switch reason {
        case .manual:
            return "Hibernated — click anywhere in the pane to resume"
        case .recovery:
            return "Parked after a restart — click anywhere in the pane to resume"
        case .merged:
            return "Hibernated after the PR merged — click anywhere in the pane to resume"
        case .auto, nil:
            return "Hibernated while idle — click anywhere in the pane to resume"
        }
    }
}

// MARK: - ScheduledResumeBanner

/// Slim footer bar shown at the bottom of the pane when the active tab's
/// terminal has a scheduled auto-resume (session limit hit, TBD will type
/// "continue" at `resumeAt`). Replaces the wide per-tab label text that used
/// to inflate tab width; background tabs still signal via a bare "⏳" glyph
/// in the tab label.
///
/// Carries an inline "Cancel" so dropping a queued auto-resume doesn't require
/// finding the tab context menu. The menu item stays as the secondary
/// affordance; both call `AppState.cancelScheduledResume`.
///
/// The button sits immediately after the message (Spacer *after* it) rather
/// than at the trailing window edge: on a wide window a far-right control is
/// visually divorced from the sentence it acts on.
private struct ScheduledResumeBanner: View {
    let resumeAt: Date
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("⏳ Auto-resume scheduled — TBD types \"continue\" at \(ResumeTimeFormatter.string(from: resumeAt))")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .lineLimit(1)
            ScheduledResumeCancelButton(action: onCancel)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15))
    }
}

/// Hand-rolled chrome rather than `.buttonStyle(.bordered)`: a `.small`
/// bordered button is ~20pt tall and would inflate this 21pt bar by a third.
/// Follows `ModelRailButton` (WorktreeProfilePickerView) — plain button, tight
/// rounded-rect — but stays outline-only (no fill) so it reads as a light
/// control against the banner's own orange wash; hover strengthens the
/// stroke instead of introducing a background. Palette kept to `.orange` so
/// no new accent color enters the bar.
private struct ScheduledResumeCancelButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("Cancel")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.orange.opacity(isHovered ? 0.85 : 0.55), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Cancel the scheduled auto-resume")
    }
}

// MARK: - QueuedPromptBanner

/// Pure decision behind the queued-prompt footer, so its precedence is
/// testable without SwiftUI — the same split `HibernatedBannerModel` uses.
enum QueuedPromptBannerModel {
    /// Show only for a `.pending` message, and only when the pane's footer slot
    /// is otherwise empty.
    ///
    /// A parked terminal yields `.hibernatedOverlay` and a rate-limited one
    /// `.scheduledResume`; in both cases nothing is running to receive a paste,
    /// so "your message goes in when the agent is ready" would be a promise the
    /// pane cannot keep. Those footers also speak to a more urgent state, and
    /// two bars stacked at the bottom edge read as noise.
    static func shows(phase: ParkedPromptPhase?, footer: HibernatedBannerModel.Banner?) -> Bool {
        phase == .pending && footer == nil
    }
}

/// Slim footer bar for a first message the daemon has not yet had an agent to
/// deliver to. Sibling of `ScheduledResumeBanner`, and deliberately so: both
/// say "TBD will type this into this pane", which is exactly the fact an
/// operator cannot otherwise see.
///
/// Informational tone (accent, like `PreSessionSetupBanner`) rather than the
/// resume banner's orange: nothing is wrong here. The whole bar is the click
/// target, opening the same composer the status bar does, so editing, Copy,
/// Discard and the send-immediately bit all live in one place.
private struct QueuedPromptBanner: View {
    @EnvironmentObject var appState: AppState
    let worktree: Worktree

    @State private var isHovered = false

    var body: some View {
        Button {
            appState.revealParkedPrompt(worktree)
        } label: {
            HStack(spacing: 6) {
                // Static glyph, not a ProgressView: a spinner would force
                // continuous CoreAnimation commits for the whole wait, for no
                // information (same rationale as PreSessionSetupBanner).
                Image(systemName: "paperplane")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 12, height: 12)
                Text("First message queued — TBD types it into the agent's composer when it is ready. Click to edit.")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(isHovered ? 0.25 : 0.15))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Read, edit or discard the first message queued for this worktree")
        .accessibilityLabel("First message queued for \(worktree.displayName). Click to edit.")
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
        // Routes through findWorktree so scratch spaces (which live in
        // `scratchWorktrees`, not the repo-grouped `worktrees` dict) resolve
        // too — otherwise selecting a scratch space shows "Worktree not found".
        appState.findWorktree(id: worktreeID)
    }

    /// The same row, proven to have a checkout on this disk. The header renders
    /// from `worktree` (a name needs no directory); the pane below needs one.
    private var localWorktree: LocalWorktree? {
        worktree.flatMap(LocalWorktree.init)
    }

    /// The terminal shown in this cell — derived from the active tab's layout
    /// so it stays consistent with the dock's visibleTerminalIDs filter.
    private var primaryTerminal: Terminal? {
        guard let tab = appState.resolvedActiveTab(worktreeID: worktreeID) else {
            return appState.terminals[worktreeID]?.first
        }
        let layout = appState.layouts[tab.id] ?? .pane(tab.content)
        // Use the first terminal in the active tab's layout tree
        guard let firstID = layout.allTerminalIDs().first else {
            return appState.terminals[worktreeID]?.first
        }
        return appState.terminals[worktreeID]?.first { $0.id == firstID }
    }

    private var activeTab: TBDShared.Tab? {
        appState.resolvedActiveTab(worktreeID: worktreeID)
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
        if let worktree = localWorktree, let terminal = primaryTerminal {
            let layoutBinding = Binding<LayoutNode>(
                get: {
                    appState.gridLayouts[worktreeID]
                        ?? .pane(.terminal(terminalID: terminal.id))
                },
                set: { newLayout in
                    appState.gridLayouts[worktreeID] = newLayout
                }
            )
            // Grid mode stays on the legacy app-side layout tree.
            PanePlaceholder(
                content: .terminal(terminalID: terminal.id),
                worktree: worktree,
                tabID: activeTab?.id,
                actions: .legacy(
                    layout: layoutBinding,
                    appState: appState,
                    worktreeID: worktree.id
                )
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
