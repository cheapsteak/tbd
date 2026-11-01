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
/// the side region on the right while it has panels — its own or the
/// worktree's — and is not collapsed (`WorkspaceTabSurface.isSideVisible`).
///
/// Each column starts with its own strip of tabs, and the two share one row:
/// this view draws the workspace tab bar over the primary's column, so the bar
/// and the side region's strip meet at the divider, which runs through the
/// row. With the region hidden, the bar spans the whole width. The bar's
/// trailing end carries the primary's viewer control
/// (`WorkspaceTabBarChrome.viewerControl`) and Session History. The
/// transcript and Notes buttons (`TabRowEdgeControls`) sit at the window's
/// right edge, just before the button that hides or shows the region: at the
/// end of the side region's strip, before its collapse button, while the
/// region shows, and at the end of the bar, before the expand button, while
/// it is hidden. This view decides them once (`edgeControls`) and hands them
/// to whichever row reaches the edge. No pane draws a header: the
/// primary's leaf gets its tab's state from `primaryChromes`, and the bar
/// draws the control that state drives. While a pre-session hook runs, the
/// primary's column shows `PreSessionSetupBanner` under the bar, so the
/// order is bar, banner, content, as on every other path.
///
/// One view serves every daemon-path tab of the worktree. `layoutContent`
/// does not key it by tab, so the tab bar inside it — an item's rename field,
/// its hover, the + button — lives on across a switch between tabs, as it
/// does where the worktree view draws the bar. Tab identity lives inside
/// instead:
/// - **The primary leaf, the divider and the side region** are keyed by the
///   tab's ID, so each tab gets a fresh terminal view and divider. The surface
///   arriving changes no ID, so it rebuilds neither.
/// - **Per-tab state is keyed by tab.** `primaryChromes` holds one control
///   state per tab, and a divider drag's shares name the tab they belong to
///   (`DividerDrag`), so no frame shows one tab's state on another.
///
/// The primary comes from the app's tab, not from the surface: it is
/// app-owned like the tab itself (panel tabs spec, "Tab sync"), and the
/// surface's copy of it only catches up after a `panel.syncTabs` round trip.
/// The side region comes from the surface, and is empty while the copy holds
/// none for the tab (`surface` nil), so a new tab draws this same view before
/// and after its surface arrives.
///
/// This view posts `MainAreaSizeKey` for its tab: its full width, and the
/// measured height of the primary leaf's slot, which lies below the tab row,
/// the divider under it and, while it shows, the pre-session banner and its
/// divider.
///
/// A divider drag, the expand button, and the transcript and Notes buttons,
/// in whichever row draws them, each send one panel operation through
/// `AppState.applyPanelOperation` and adopt the tab the daemon returns; the
/// Notes button in a worktree with no note creates one first
/// (`AppState.toggleNotesPanel`). The transcript button in front of any
/// primary but a Claude terminal is disabled and sends nothing. The
/// rendered/source toggle and copy-address act on the tab's chrome state and
/// send nothing.
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
    /// The worktree's tab IDs, which `primaryChromes` is pruned to. The
    /// worktree view, which observes the tab list, hands them in, so this
    /// body reads no `AppState.tabs` and a tab written in another worktree
    /// does not re-evaluate it.
    let tabIDs: [UUID]
    /// Whether the pre-session setup banner shows under the tab bar
    /// (`AppState.showsPreSessionBanner`).
    let showsPreSessionBanner: Bool
    @Environment(AppState.self) var appState

    /// The divider's shares while a drag on it is being committed: set when
    /// the drag is released, cleared once its `resize` has been applied or
    /// refused. Otherwise the shares follow the surface's width.
    @State private var dividerDrag: DividerDrag?
    /// The primary's control state per tab: the rendered/source toggle,
    /// whether its file can render, its web page's address and the copy
    /// checkmark. Pruned to the worktree's tabs as they change.
    @State private var primaryChromes = PaneChromeStore()
    @AppStorage(AppState.enableTranscriptKey)
    private var transcriptViewEnabled = AppState.enableTranscriptDefault

    init(
        tab: TBDShared.Tab,
        surface: WorkspaceTabSurface?,
        worktree: LocalWorktree,
        tabIDs: [UUID],
        showsPreSessionBanner: Bool,
        makeTabBar: @escaping @MainActor (TabBarTrailingItems) -> TabBar
    ) {
        self.tab = tab
        self.surface = surface
        self.worktree = worktree
        self.tabIDs = tabIDs
        self.showsPreSessionBanner = showsPreSessionBanner
        self.makeTabBar = makeTabBar
    }

    /// The side region drawn: the surface's, or an empty one without it.
    private var side: SideRegion { Self.sideRegion(of: surface) }

    var body: some View {
        let side = self.side
        let tabID = tab.id
        let chrome = primaryChromes.state(for: tabID)
        let showsSide = Self.showsSide(surface: surface)
        // Read here, not in the `GeometryReader` closure, so what the edge
        // controls and the bar's trailing items read is a dependency of this
        // body.
        let edge = Self.edgeControls(
            appState: appState, worktreeID: worktree.id, tabID: tabID, primary: primaryContent,
            surface: surface, transcriptViewEnabled: transcriptViewEnabled)
        let trailing = trailingItems(chrome: chrome, edge: edge, showsSide: showsSide)
        GeometryReader { geometry in
            let thickness = SplitDividerMetrics.lineThickness
            let availableSpace = max(geometry.size.width - thickness, 0)
            let shares = Self.shares(drag: dividerDrag, tabID: tabID, width: side.width)

            // The primary's column stays the first child whatever the side
            // region does, so showing or hiding the region never rebuilds the
            // primary's terminal view.
            HStack(spacing: 0) {
                primaryColumn(trailing: trailing, chrome: chrome, mainAreaWidth: geometry.size.width)
                    .frame(width: showsSide ? shares[0] * availableSpace : geometry.size.width)

                if showsSide, let surface {
                    SplitDivider(
                        direction: .horizontal,
                        thickness: thickness,
                        index: 0,
                        ratios: Binding(
                            get: { Self.shares(drag: dividerDrag, tabID: tabID, width: side.width) },
                            set: { dividerDrag = DividerDrag(tabID: tabID, ratios: $0) }
                        ),
                        availableSpace: availableSpace,
                        onDragEnd: { commitWidth() }
                    )
                    .id(tabID)
                    .zIndex(1)

                    SideRegionView(surface: surface, worktree: worktree, edge: edge)
                        .id(tabID)
                        .frame(width: shares[1] * availableSpace)
                }
            }
        }
        .onChange(of: tabIDs) { _, tabIDs in
            primaryChromes.prune(keeping: Set(tabIDs))
        }
    }

    /// The primary leaf's content: the app's tab, never `surface.primary`. A
    /// primary re-pointed in the app — the file viewer pointing a file tab at
    /// a new file — shows at once, and still shows if the sync that carries it
    /// to the daemon fails.
    var primaryContent: PaneContent { tab.content }

    /// The workspace tab bar with `trailing` at its end, a divider, the
    /// pre-session banner and its divider while that shows, and the
    /// primary's leaf, which draws no header. The bar keeps its identity
    /// across tabs; the leaf is keyed by the tab, so each tab gets a fresh
    /// terminal view and web view, the latter reporting to that tab's
    /// `chrome`. The banner coming or going leaves the leaf where it is in
    /// the column, so it rebuilds nothing.
    ///
    /// A reader behind the leaf measures its slot and posts the slot's height
    /// as `MainAreaSizeKey`, with `mainAreaWidth`, this view's full width: the
    /// one producer of the key on this path.
    private func primaryColumn(
        trailing: TabBarTrailingItems, chrome: PaneChromeState, mainAreaWidth: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            makeTabBar(trailing)

            Divider()

            if showsPreSessionBanner {
                PreSessionSetupBanner()

                Divider()
            }

            PanePlaceholder(
                content: primaryContent,
                worktree: worktree,
                tabID: tab.id,
                actions: .daemon(
                    appState: appState, worktreeID: worktree.id, tabID: tab.id, panelID: nil),
                chrome: chrome
            )
            .id(tab.id)
            .background {
                GeometryReader { leaf in
                    Color.clear.preference(
                        key: MainAreaSizeKey.self,
                        value: Self.mainAreaSize(width: mainAreaWidth, primaryLeafHeight: leaf.size.height))
                }
            }
        }
    }

    /// The bar's trailing items (`TabBarTrailingItem.items`): the primary's
    /// viewer control, read from `chrome`, and Session History; then, while
    /// the side region is hidden (`showsSide` false), the transcript and Notes
    /// buttons from `edge`, and the expand button once the tab's surface is
    /// known (`showsExpandButton`).
    private func trailingItems(
        chrome: PaneChromeState, edge: TabRowEdgeControls, showsSide: Bool
    ) -> TabBarTrailingItems {
        let appState = appState
        let worktreeID = worktree.id
        let tabID = tab.id
        let content = primaryContent
        let surface = surface
        let viewerControl = WorkspaceTabBarChrome.viewerControl(
            primary: content,
            canRender: chrome.hasRenderableContent,
            showingSource: chrome.showSourceCode,
            copied: chrome.didCopyAddress)

        return TabBarTrailingItems(
            viewerControl: viewerControl,
            onViewerControl: {
                // The viewer controls act on the tab's chrome state, as the
                // side region's strip does.
                guard let viewerControl else { return }
                var contentURL: URL?
                if case .webview(_, let url) = content {
                    contentURL = url
                }
                chrome.perform(viewerControl, contentURL: contentURL)
            },
            edge: edge,
            showsSide: showsSide,
            showsExpandButton: Self.showsExpandButton(surface: surface),
            onExpand: {
                appState.sendPanelOperation(
                    worktreeID: worktreeID, tabID: tabID, Self.expandOperation(surface: surface))
            })
    }

    /// The transcript and Notes buttons of the workspace tab `tabID`, whose
    /// primary is `primary`, with what a press of each sends. One function
    /// decides both, so the side region's strip and the workspace tab bar,
    /// whichever reaches the window's right edge, draw the same two buttons.
    ///
    /// - **The transcript button** is the one
    ///   `WorkspaceTabBarChrome.transcriptControl` decides: on while a Claude
    ///   terminal's transcript panel exists, whether or not it is in front.
    ///   Enabled, a press opens, selects or closes that panel through the
    ///   daemon action set (`PaneActions.toggleTranscript`), the only set that
    ///   can send it; disabled, a press sends nothing.
    /// - **The Notes button** (`notesControl`) shows, brings forward or closes
    ///   the worktree's first note (`AppState.toggleNotesPanel`).
    @MainActor
    static func edgeControls(
        appState: AppState,
        worktreeID: UUID,
        tabID: UUID,
        primary: PaneContent,
        surface: WorkspaceTabSurface?,
        transcriptViewEnabled: Bool
    ) -> TabRowEdgeControls {
        var isClaudeTerminal = false
        var transcriptOpen = false
        if case .terminal(let terminalID) = primary {
            isClaudeTerminal = appState.terminal(id: terminalID, in: worktreeID)?.isClaudeResumable == true
            if isClaudeTerminal && transcriptViewEnabled {
                transcriptOpen = PaneActions.daemon(
                    appState: appState, worktreeID: worktreeID, tabID: tabID, panelID: nil
                ).isTranscriptOpen(terminalID)
            }
        }
        let transcript = WorkspaceTabBarChrome.transcriptControl(
            primary: primary,
            isClaudeTerminal: isClaudeTerminal,
            transcriptViewEnabled: transcriptViewEnabled,
            transcriptOpen: transcriptOpen)

        return TabRowEdgeControls(
            transcript: transcript,
            onTranscript: {
                guard transcript?.isEnabled == true, case .terminal(let terminalID) = primary else { return }
                PaneActions.daemon(
                    appState: appState, worktreeID: worktreeID, tabID: tabID, panelID: nil
                ).toggleTranscript(primary, terminalID)
            },
            notes: notesControl(surface: surface, notes: appState.notes[worktreeID]),
            onNotes: {
                Task { @MainActor in
                    await appState.toggleNotesPanel(worktreeID: worktreeID, tabID: tabID)
                }
            })
    }

    /// Sends the released drag's width, clamped to the model's range, for the
    /// tab the drag was on. With nothing to send, or once the apply has
    /// finished, the drag's shares are dropped and the divider follows the
    /// copy: an adopted reply has already moved it there, and a failed apply
    /// leaves the copy where it was. A later drag keeps its own shares.
    private func commitWidth() {
        let appState = appState
        let worktreeID = worktree.id
        guard let drag = dividerDrag, drag.tabID == tab.id,
              let operation = Self.resizeOperation(ratios: drag.ratios, currentWidth: side.width)
        else {
            dividerDrag = nil
            return
        }
        Task { @MainActor in
            _ = await appState.applyPanelOperation(worktreeID: worktreeID, tabID: drag.tabID, operation)
            if dividerDrag == drag {
                dividerDrag = nil
            }
        }
    }

    // MARK: - Pure helpers

    /// A divider drag's shares, held for the tab the drag was on.
    struct DividerDrag: Equatable {
        let tabID: UUID
        let ratios: [CGFloat]
    }

    /// The divider's `[primary, side]` shares for the tab `tabID`: a drag's
    /// while one on this tab is being committed, otherwise the side region's
    /// `width`. A drag on another tab, or one with malformed shares, is not
    /// this tab's.
    static func shares(drag: DividerDrag?, tabID: UUID, width: Double) -> [CGFloat] {
        if let drag, drag.tabID == tabID, drag.ratios.count == 2 {
            return drag.ratios
        }
        return Self.ratios(forWidth: width)
    }

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

    /// The size this view posts as `MainAreaSizeKey`: its full `width`, the
    /// side region included, and the measured height of the primary leaf's
    /// slot. Measured rather than derived from this view's height, so the
    /// tab row, the banner and their dividers are left out at whatever height
    /// they lay out, as the slot every other path measures leaves them out.
    static func mainAreaSize(width: CGFloat, primaryLeafHeight: CGFloat) -> CGSize {
        CGSize(width: width, height: primaryLeafHeight)
    }

    /// The Notes button at the window's right edge, as the side region's
    /// strip or the workspace tab bar draws it: on while the worktree's first
    /// note is in front of a visible side region, so a press would close it
    /// (`NotesToggleDecision.isOn`), and disabled while the worktree's notes,
    /// `notes`, have not loaded and the tab shows no note panel
    /// (`NotesToggleDecision.unavailable`).
    static func notesControl(surface: WorkspaceTabSurface?, notes: [NoteSummary]?) -> PaneChromeControl {
        let decision = PaneActions.notesToggleDecision(surface: surface, notes: notes)
        return .notes(isOn: decision.isOn, isEnabled: decision.isEnabled)
    }

    /// Whether the side region draws beside the primary: once the tab's
    /// surface is known and its region is visible
    /// (`WorkspaceTabSurface.isSideVisible`). Before the copy holds a surface
    /// for the tab (`surface` nil) it does not, so the workspace tab bar spans
    /// the whole width and carries the transcript and Notes buttons.
    static func showsSide(surface: WorkspaceTabSurface?) -> Bool {
        surface?.isSideVisible ?? false
    }

    /// The expand button shows once the tab's surface is known and its side
    /// region is hidden: collapsed, or without a panel of its own or the
    /// worktree's. It never shows while the region is visible, when the
    /// strip's collapse button carries `⌘\`, nor before the copy holds a
    /// surface for the tab (`surface` nil): the region's real state is
    /// unknown then, and it may be collapsed over panels, which an expand
    /// should uncollapse rather than open Changes in front of.
    static func showsExpandButton(surface: WorkspaceTabSurface?) -> Bool {
        guard let surface else { return false }
        return !surface.isSideVisible
    }

    /// What the expand button sends: a region with panels is uncollapsed; one
    /// with none, or a tab with no surface yet, opens the Changes list, so the
    /// button always shows something.
    static func expandOperation(surface: WorkspaceTabSurface?) -> PanelOperation {
        if surface?.hasPanels == true {
            return .setCollapsed(false)
        }
        return .open(content: .changes, newPanel: false)
    }
}

// MARK: - WorkspaceTabBarChrome

/// The two controls the workspace tab's primary decides (panel tabs spec,
/// "The renderer" and "The transcript button"): its viewer control, at the
/// workspace tab bar's trailing end, and the transcript button, at the
/// window's right edge. Decided as values so each kind can be asserted
/// without standing up a view.
enum WorkspaceTabBarChrome {
    /// The primary's own control, drawn at the workspace tab bar's trailing
    /// end before Session History. Viewer content takes the control the side
    /// region's strip gives the same kind (`PaneChromeControl.viewerControl`):
    /// the rendered/source toggle for a file that can render, and copy-address
    /// for a web page. A terminal, a note and a transcript primary have none.
    static func viewerControl(
        primary: PaneContent,
        canRender: Bool,
        showingSource: Bool,
        copied: Bool
    ) -> PaneChromeControl? {
        guard let viewer = LegacyTabConverter.panelContent(from: primary) else { return nil }
        return PaneChromeControl.viewerControl(
            for: viewer.kind, canRender: canRender, showingSource: showingSource, copied: copied)
    }

    /// The transcript button at the window's right edge, or nil for none.
    /// With the transcript view off no tab has one. With it on, every tab
    /// draws one: live in front of a Claude terminal, and on while that
    /// terminal's transcript panel exists (`transcriptOpen`); disabled in
    /// front of any other primary — a plain or Codex terminal, a file, a web
    /// page, a note or a transcript.
    ///
    /// Disabled rather than removed, as the side region's history buttons
    /// are (`SideStripHistoryButtons`) and as the Notes button is while it
    /// cannot act: the buttons before it — Session History while the region
    /// is hidden, the + menu and the active panel's control while it shows —
    /// would otherwise shift by a button's width whenever the selection moved
    /// between a Claude terminal's tab and any other.
    static func transcriptControl(
        primary: PaneContent,
        isClaudeTerminal: Bool,
        transcriptViewEnabled: Bool,
        transcriptOpen: Bool
    ) -> PaneChromeControl? {
        guard transcriptViewEnabled else { return nil }
        guard case .terminal = primary, isClaudeTerminal else {
            return .transcript(isOn: false, isEnabled: false)
        }
        return .transcript(isOn: transcriptOpen, isEnabled: true)
    }
}
