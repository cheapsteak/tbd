import SwiftUI
import TBDShared

/// The `.task(id:)` key for loading a worktree's surfaces into the app's copy
/// (`AppState.panelSurfaceLoadKey`). A load runs while the shown tab has no
/// surface in the copy, so one starts when such a tab is shown — in a newly
/// shown worktree, or by a tab switch. That is the backstop for a tab a
/// failed `panel.get`, or an import delta missed while the subscription was
/// down, left without a surface: it loads again when it is shown, instead of
/// drawing an empty side region until the user picks another worktree. A
/// shown tab with a surface asks for no load: one load fills every tab of the
/// worktree and deltas keep the copy current, so switching between such tabs
/// costs no `panel.get`. Neither does a tab the last tab sync skipped
/// (`panelSyncSkippedTabIDs`): the daemon could not import its legacy layout,
/// so no load would find a surface for it, and it renders legacy until a
/// change to its layout offers it again. Not the resubscribe either: its
/// acknowledgement refetches every worktree with a tab list itself. A struct
/// rather than an interpolated string, so a new dimension is a compile error
/// at the call site instead of a key that silently stays equal.
struct PanelSurfaceLoadKey: Equatable {
    let worktreeID: UUID
    /// A tab is shown, the copy holds no surface for it, and the last tab
    /// sync did not skip it.
    let activeTabAwaitsSurface: Bool

    /// Whether the task this key starts loads the worktree's surfaces.
    var loads: Bool { activeTabAwaitsSurface }
}

// MARK: - PanelSurfaceWorkspaceView

/// One workspace tab drawn from the daemon-owned surface (panel tabs spec,
/// "The renderer"): the primary's column on the left, the split divider, and
/// the side region on the right while it has panels and is not collapsed.
///
/// Each column starts with its own strip of tabs, and the two share one row:
/// this view draws the workspace tab bar over the primary's column, so the bar
/// and the side region's strip meet at the divider, which runs through the
/// row. With the region hidden, the bar spans the whole width. The bar's
/// trailing end carries the selected tab's own control
/// (`WorkspaceTabBarChrome`), Session History, and the expand button while
/// the region is collapsed and has panels. No pane draws a header: the
/// primary's leaf gets `primaryChrome`, the state its control reads, and the
/// bar draws the control.
///
/// The primary comes from the app's tab, not from the surface: it is
/// app-owned like the tab itself (panel tabs spec, "Tab sync"), and the
/// surface's copy of it only catches up after a `panel.syncTabs` round trip.
/// The side region comes from the surface, and is empty while the copy holds
/// none for the tab (`surface` nil), so a new tab draws this same view before
/// and after its surface arrives.
///
/// This view posts `MainAreaSizeKey` for its tab: its full width, and its
/// height below the tab row and the divider under it.
///
/// A divider drag, the expand button and the transcript control each send one
/// panel operation through `AppState.applyPanelOperation` and adopt the tab
/// the daemon returns. The rendered/source toggle and copy-address act on
/// `primaryChrome` and send nothing. The only other local state is the
/// divider's overlay while a drag is committing.
struct PanelSurfaceWorkspaceView: View {
    let tab: TBDShared.Tab
    /// The copy's surface for this tab, or nil while it holds none yet.
    let surface: WorkspaceTabSurface?
    let worktree: LocalWorktree
    /// Builds the workspace tab bar, handed the trailing items this view
    /// decides. The worktree view owns the bar's tabs and their actions (and
    /// the account picker sheet the + menu opens), so it supplies the bar and
    /// this view only places it.
    let makeTabBar: @MainActor (TabBarTrailingItems) -> TabBar
    @Environment(AppState.self) var appState

    /// `[primary, side]` shares for the divider. A drag changes them only
    /// here, and one `resize` goes out on release; the adopted reply, or a
    /// width another client set, resets them from the surface.
    @State private var ratios: [CGFloat]
    /// The primary's control state: the rendered/source toggle, whether its
    /// file can render, its web page's address and the copy checkmark. One
    /// per tab, since the view is keyed by the tab's ID.
    @State private var primaryChrome = PaneChromeState()
    @AppStorage(AppState.enableTranscriptKey)
    private var transcriptViewEnabled = AppState.enableTranscriptDefault

    init(
        tab: TBDShared.Tab,
        surface: WorkspaceTabSurface?,
        worktree: LocalWorktree,
        makeTabBar: @escaping @MainActor (TabBarTrailingItems) -> TabBar
    ) {
        self.tab = tab
        self.surface = surface
        self.worktree = worktree
        self.makeTabBar = makeTabBar
        _ratios = State(initialValue: Self.ratios(forWidth: Self.sideRegion(of: surface).width))
    }

    /// The side region drawn: the surface's, or an empty one without it.
    private var side: SideRegion { Self.sideRegion(of: surface) }

    var body: some View {
        let side = self.side
        GeometryReader { geometry in
            let showsSide = side.isVisible
            let thickness = SplitDividerMetrics.lineThickness
            let availableSpace = max(geometry.size.width - thickness, 0)
            let shares = ratios.count == 2 ? ratios : Self.ratios(forWidth: side.width)

            // The primary's column stays the first child whatever the side
            // region does, so showing or hiding the region never rebuilds the
            // primary's terminal view.
            HStack(spacing: 0) {
                primaryColumn(side: side)
                    .frame(width: showsSide ? shares[0] * availableSpace : geometry.size.width)

                if showsSide, let surface {
                    SplitDivider(
                        direction: .horizontal,
                        thickness: thickness,
                        index: 0,
                        ratios: $ratios,
                        availableSpace: availableSpace,
                        onDragEnd: { commitWidth() }
                    )
                    .zIndex(1)

                    SideRegionView(surface: surface, worktree: worktree)
                        .frame(width: shares[1] * availableSpace)
                }
            }
            .preference(key: MainAreaSizeKey.self, value: Self.mainAreaSize(of: geometry.size))
        }
        .onChange(of: side.width) { _, width in
            ratios = Self.ratios(forWidth: width)
        }
    }

    /// The primary leaf's content: the app's tab, never `surface.primary`. A
    /// primary re-pointed in the app — the file viewer pointing a file tab at
    /// a new file — shows at once, and still shows if the sync that carries it
    /// to the daemon fails.
    var primaryContent: PaneContent { tab.content }

    /// The workspace tab bar, a divider, and the primary's leaf, which draws
    /// no header.
    private func primaryColumn(side: SideRegion) -> some View {
        VStack(spacing: 0) {
            makeTabBar(trailingItems(side: side))

            Divider()

            PanePlaceholder(
                content: primaryContent,
                worktree: worktree,
                tabID: tab.id,
                actions: .daemon(
                    appState: appState, worktreeID: worktree.id, tabID: tab.id, panelID: nil),
                chrome: primaryChrome
            )
        }
    }

    /// The bar's trailing items: the primary's control, and the expand button
    /// while `side` is collapsed with panels.
    private func trailingItems(side: SideRegion) -> TabBarTrailingItems {
        let appState = appState
        let worktreeID = worktree.id
        let tabID = tab.id
        let content = primaryContent
        let chrome = primaryChrome

        var isClaudeTerminal = false
        var transcriptOpen = false
        if case .terminal(let terminalID) = content {
            isClaudeTerminal = appState.terminal(id: terminalID, in: worktreeID)?.isClaudeResumable == true
            if isClaudeTerminal && transcriptViewEnabled {
                transcriptOpen = PaneActions.daemon(
                    appState: appState, worktreeID: worktreeID, tabID: tabID, panelID: nil
                ).isTranscriptOpen(terminalID)
            }
        }
        let control = WorkspaceTabBarChrome.trailingControl(
            primary: content,
            isClaudeTerminal: isClaudeTerminal,
            transcriptViewEnabled: transcriptViewEnabled,
            transcriptOpen: transcriptOpen,
            canRender: chrome.hasRenderableContent,
            showingSource: chrome.showSourceCode,
            copied: chrome.didCopyAddress)

        return TabBarTrailingItems(
            selectedTabControl: control,
            onSelectedTabControl: {
                switch content {
                case .terminal(let terminalID):
                    PaneActions.daemon(
                        appState: appState, worktreeID: worktreeID, tabID: tabID, panelID: nil
                    ).toggleTranscript(content, terminalID)
                case .codeViewer:
                    chrome.showSourceCode.toggle()
                case .webview(_, let url):
                    chrome.copyAddress(chrome.webviewState.currentURL ?? url)
                case .note, .liveTranscript:
                    break
                }
            },
            showsExpandButton: Self.showsExpandButton(side: side),
            onExpand: {
                appState.sendPanelOperation(worktreeID: worktreeID, tabID: tabID, .setCollapsed(false))
            })
    }

    /// Sends the drag's width, clamped to the model's range. With nothing to
    /// send, or once the apply has finished, the overlay snaps to the copy: an
    /// adopted reply has already moved it there, and a failed apply leaves the
    /// copy where it was.
    private func commitWidth() {
        let appState = appState
        let worktreeID = worktree.id
        let tabID = tab.id
        let heldWidth = side.width
        guard let operation = Self.resizeOperation(ratios: ratios, currentWidth: heldWidth) else {
            ratios = Self.ratios(forWidth: heldWidth)
            return
        }
        Task { @MainActor in
            _ = await appState.applyPanelOperation(worktreeID: worktreeID, tabID: tabID, operation)
            let width = appState.panelSurface(worktreeID: worktreeID, tabID: tabID)?.side.width ?? heldWidth
            ratios = Self.ratios(forWidth: width)
        }
    }

    // MARK: - Pure helpers

    /// A surface's side region, or `SideRegion.empty` for none.
    static func sideRegion(of surface: WorkspaceTabSurface?) -> SideRegion {
        surface?.side ?? .empty
    }

    /// The divider's `[primary, side]` shares for a side-region width, clamped
    /// by `SideRegion.clamp`, the divider's own limit.
    static func ratios(forWidth width: Double) -> [CGFloat] {
        let clamped = SideRegion.clamp(width)
        return [CGFloat(1 - clamped), CGFloat(clamped)]
    }

    /// The `resize` a released drag sends: the side's share, clamped. Nil when
    /// the ratios are malformed or not finite, or the width did not change, so
    /// a click on the divider sends nothing. A non-finite share is no width
    /// the user chose: `SideRegion.clamp` would turn it into the default, and
    /// a resize to that would move the divider nobody dragged there.
    static func resizeOperation(ratios: [CGFloat], currentWidth: Double) -> PanelOperation? {
        guard ratios.count == 2, ratios[1].isFinite else { return nil }
        let width = SideRegion.clamp(Double(ratios[1]))
        guard width != currentWidth else { return nil }
        return .resize(width: width)
    }

    /// The size this view posts as `MainAreaSizeKey`: all of `size` but the
    /// tab row and the divider under it, so the measure excludes the tab bar
    /// as it does on every other path.
    static func mainAreaSize(of size: CGSize) -> CGSize {
        CGSize(width: size.width, height: max(size.height - TabRowMetrics.height - 1, 0))
    }

    /// The expand button shows while the region is collapsed and has panels to
    /// show; an empty region has nothing to expand. It never shows while the
    /// region is visible, when the strip's collapse button carries `⌘\`.
    static func showsExpandButton(side: SideRegion) -> Bool {
        side.collapsed && !side.panels.isEmpty
    }
}

// MARK: - WorkspaceTabBarChrome

/// The selected tab's own control at the workspace tab bar's trailing end
/// (panel tabs spec, "The renderer"), decided as a value so each kind can be
/// asserted without standing up a view.
enum WorkspaceTabBarChrome {
    /// The transcript button for a Claude terminal while the transcript view
    /// is on, the rendered/source toggle for a file that can render, and
    /// copy-address for a web page. A note, a plain terminal and a transcript
    /// primary have none.
    static func trailingControl(
        primary: PaneContent,
        isClaudeTerminal: Bool,
        transcriptViewEnabled: Bool,
        transcriptOpen: Bool,
        canRender: Bool,
        showingSource: Bool,
        copied: Bool
    ) -> PaneChromeControl? {
        switch primary {
        case .terminal:
            guard isClaudeTerminal, transcriptViewEnabled else { return nil }
            return .transcript(isOn: transcriptOpen)
        case .codeViewer:
            guard canRender else { return nil }
            return .renderToggle(showingSource: showingSource)
        case .webview:
            return .copyAddress(copied: copied)
        case .note, .liveTranscript:
            return nil
        }
    }
}
