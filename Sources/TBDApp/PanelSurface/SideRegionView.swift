import SwiftUI
import TBDShared

// MARK: - Strip model

/// One tab in the side region's strip, decided from the surface as a value so
/// the strip can be asserted without standing up a view.
struct SideRegionTab: Equatable, Identifiable {
    let id: PanelID
    /// The panel's current content: its history's cursor entry.
    let content: PanelContent
    let title: String
    let isActive: Bool
    /// The session `.jsonl` a transcript tab's file menu acts on. Nil for the
    /// other kinds, and until the terminal's row carries one.
    let transcriptPath: String?
    /// One of the worktree's panels — a note or the Changes list — which
    /// every workspace tab of the worktree shows, rather than one of this
    /// workspace tab's own.
    let isWorktreeWide: Bool

    /// The content as the leaf view, and the file menu, take it; nil for the
    /// Changes list, which has no leaf form.
    var paneContent: PaneContent? { content.paneContent(panelID: id) }

    /// The note a note tab shows, which its rename titles and its × deletes;
    /// nil for the other kinds.
    var noteID: UUID? {
        guard case .note(let noteID) = content else { return nil }
        return noteID
    }

    /// The symbol the workspace tab bar shows for the same kind; nil for a
    /// file, whose tab shows its name alone.
    var systemImage: String? { content.kind.tabSystemImage }

    /// A web page's address, which its copy-address control copies until the
    /// page reports one of its own; nil for the other kinds.
    var webURL: URL? {
        guard case .web(let url) = content else { return nil }
        return url
    }

    /// The tab's hover text: a web page's full address, which its title (the
    /// host) leaves out, and every other tab's title.
    var tooltip: String {
        webURL?.absoluteString ?? title
    }
}

/// Which of the strip's three history buttons — search, back, forward — can
/// act on the active panel. A button that cannot is drawn disabled, never
/// removed, so the tabs after it stay where they are.
struct SideStripHistoryButtons: Equatable {
    let search: Bool
    let back: Bool
    let forward: Bool
}

/// The widths of the strip's fixed controls, which the strip draws with and
/// the side region's minimum width is made of, so the two cannot drift apart.
enum SideStripMetrics {
    /// The inset before the history buttons.
    static let historyLeadingInset: CGFloat = 4
    /// Each history button's width: search, back and forward, each a row
    /// icon button's square (`RowIconButtonStyle`).
    static let historyButtonWidth: CGFloat = TabRowMetrics.controlWidth
    /// Search, back and forward.
    static let historyButtonCount = 3
    /// The most items the trailing group holds: the active panel's control,
    /// the Changes, transcript and Notes pills, and collapse. The most, not
    /// the current count, so the region's minimum width stays put as the
    /// active panel, the transcript setting or the worktree's changes come and
    /// go; a pill that is not drawn, such as Changes for a worktree with none,
    /// only leaves the tabs more room.
    static let trailingSlotCount = 5

    /// The width the strip's fixed controls need, in whole points: the
    /// history buttons with their inset; a full trailing group, its
    /// transcript and Notes pills at their labelled widths
    /// (`SidePanelPillMetrics.labelledWidth`, one per
    /// `TabRowEdgeItem.pillLabels`) and its other slots, the active panel's
    /// control, the Changes pill and collapse, each a
    /// `TabRowMetrics.controlWidth` square; and the strip's trailing inset
    /// (`MainTabRowMetrics.trailingInset`). The panel tabs between them need
    /// none, since they scroll and give up their room first. The side region
    /// is kept at least this wide (`PanelSurfaceWorkspaceView.minimumSideShare`),
    /// so no pill and no button is ever clipped. Measured on macOS 27, it is
    /// 335 pt.
    @MainActor
    static var fixedControlsWidth: CGFloat {
        let labels = TabRowEdgeItem.pillLabels
        let labelledPillsWidth: CGFloat = labels.reduce(0) { $0 + SidePanelPillMetrics.labelledWidth($1) }
        return historyLeadingInset
            + CGFloat(historyButtonCount) * historyButtonWidth
            + labelledPillsWidth
            + CGFloat(trailingSlotCount - labels.count) * TabRowMetrics.controlWidth
            + MainTabRowMetrics.trailingInset
    }
}

/// A note of the worktree that the Notes pill's Open Other Note menu lists
/// (`SideRegionStrip.otherNotes`), titled as its tab would be.
struct SideStripOtherNote: Equatable, Identifiable {
    let id: UUID
    let title: String
}

enum SideRegionStrip {
    /// Every panel the strip can show: the worktree's panels first, in the
    /// worktree's order, then the tab's own panels, in the region's order. An
    /// own panel with no current content — only malformed decoded data can
    /// produce one — is left out rather than drawn blank. A note is titled
    /// from its summary in `notes`, the worktree's entry in
    /// `AppState.notes`. The active panel is found among these; the strip
    /// draws a tab for each one no pill stands for (`tabs`).
    static func panels(
        for surface: WorkspaceTabSurface,
        notes: [NoteSummary]?,
        transcriptPath: (UUID) -> String?
    ) -> [SideRegionTab] {
        let activePanelID = surface.side.activePanelID
        let noteTitle: (UUID) -> String? = { noteID in
            notes?.first(where: { $0.id == noteID })?.title
        }
        let worktreeTabs = surface.worktreePanels.map { panel -> SideRegionTab in
            let content = panel.content.panelContent
            return SideRegionTab(
                id: panel.id,
                content: content,
                title: title(for: content, noteTitle: noteTitle),
                isActive: panel.id == activePanelID,
                transcriptPath: nil,
                isWorktreeWide: true)
        }
        let ownTabs = surface.side.panels.compactMap { panel -> SideRegionTab? in
            guard let content = panel.content else { return nil }
            var path: String?
            if case .transcript(let terminalID) = content,
               let resolved = transcriptPath(terminalID), !resolved.isEmpty {
                path = resolved
            }
            return SideRegionTab(
                id: panel.id,
                content: content,
                title: title(for: content, noteTitle: noteTitle),
                isActive: panel.id == activePanelID,
                transcriptPath: path,
                isWorktreeWide: false)
        }
        return worktreeTabs + ownTabs
    }

    /// The panels a pill stands for, which get no tab of their own: the
    /// Changes panel, the worktree's first note's panel (`PaneActions.firstNote`,
    /// the note the Notes pill toggles), and the transcript panel of
    /// `transcriptTerminalID`, the Claude terminal the transcript pill
    /// toggles (`TabRowEdgeControls.transcriptTerminalID`). With no
    /// transcript pill that can act, `transcriptTerminalID` is nil and every
    /// transcript panel keeps its tab, as does one of any other terminal.
    static func pillPanelIDs(
        surface: WorkspaceTabSurface,
        notes: [NoteSummary]?,
        transcriptTerminalID: UUID?
    ) -> Set<PanelID> {
        var ids = Set<PanelID>()
        if let changes = surface.worktreePanel(showing: .changes) {
            ids.insert(changes.id)
        }
        if let firstNotePanel = PaneActions.firstNote(surface: surface, notes: notes)?.panel {
            ids.insert(firstNotePanel.id)
        }
        if let transcriptTerminalID {
            let transcript = PanelContent.transcript(terminalID: transcriptTerminalID)
            for panel in surface.side.panels where panel.content == transcript {
                ids.insert(panel.id)
            }
        }
        return ids
    }

    /// The strip's tabs: every panel (`panels`) but those a pill stands for
    /// (`pillPanelIDs`) — files, web pages, and any note other than the
    /// first, each with its ×.
    static func tabs(
        for surface: WorkspaceTabSurface,
        notes: [NoteSummary]?,
        transcriptTerminalID: UUID?,
        transcriptPath: (UUID) -> String?
    ) -> [SideRegionTab] {
        let pilled = pillPanelIDs(surface: surface, notes: notes, transcriptTerminalID: transcriptTerminalID)
        return panels(for: surface, notes: notes, transcriptPath: transcriptPath)
            .filter { !pilled.contains($0.id) }
    }

    /// The Notes pill's Open Other Note menu: every note in `notes` other
    /// than the first (`PaneActions.firstNote`) that no worktree panel shows,
    /// in `notes` order, titled as its tab would be — an untitled note reads
    /// "Note". Nothing in the app makes a note beside the first, so these are
    /// notes a worktree already held, and this menu is the one control that
    /// reaches one with no panel. Empty while `notes` has not loaded, and
    /// when every note but the first has a panel, so the menu leaves the item
    /// out.
    static func otherNotes(notes: [NoteSummary]?, surface: WorkspaceTabSurface) -> [SideStripOtherNote] {
        guard let notes else { return [] }
        let firstNoteID = PaneActions.firstNote(surface: surface, notes: notes)?.noteID
        return notes.compactMap { note -> SideStripOtherNote? in
            guard note.id != firstNoteID, surface.worktreePanel(showing: .note(noteID: note.id)) == nil else {
                return nil
            }
            return SideStripOtherNote(
                id: note.id,
                title: title(for: .note(noteID: note.id), noteTitle: { _ in note.title }))
        }
    }

    /// The operation Open Other Note sends for `note`: open it, which the
    /// daemon shows as a worktree panel with a tab of its own, in front in
    /// this tab.
    static func openOperation(for note: SideStripOtherNote) -> PanelOperation {
        .open(content: .note(noteID: note.id), newPanel: false)
    }

    /// The title the workspace tab bar gives the same content
    /// (`PanelContent.tabTitle`), except that a note with no title shows
    /// "Note": a side-region tab has no position number to give it.
    static func title(for content: PanelContent, noteTitle: (UUID) -> String?) -> String {
        content.tabTitle(noteTitle: noteTitle, untitledNote: "Note")
    }

    /// The history buttons for the active panel's `content` and `history`.
    /// A file or web panel steps through its history: search while it has
    /// entries, back toward older entries and forward toward newer ones as
    /// the cursor allows. A note, transcript or Changes panel has no history
    /// to step through, and neither does a panel whose history is unknown, so
    /// all three are disabled.
    static func historyButtons(for content: PanelContent, history: PaneHistory?) -> SideStripHistoryButtons {
        switch content {
        case .file, .web:
            guard let history else { break }
            return SideStripHistoryButtons(
                search: PaneHistoryPaletteButtonModel.isEnabled(entryCount: history.entries.count),
                back: history.canGoBack,
                forward: history.canGoForward)
        case .note, .transcript, .changes:
            break
        }
        return SideStripHistoryButtons(search: false, back: false, forward: false)
    }

    /// The active panel's own control, drawn after the tabs and before the
    /// Changes, transcript and Notes pills (`SideStripTrailingItem.items`):
    /// its kind's viewer control (`PaneChromeControl.viewerControl`), the
    /// rendered/source toggle for a file that can render, copy-address for a
    /// web page and refresh for the Changes list. A file that cannot render,
    /// a note and a transcript have none.
    static func trailingControl(
        for content: PanelContent,
        canRender: Bool,
        showingSource: Bool,
        copied: Bool
    ) -> PaneChromeControl? {
        PaneChromeControl.viewerControl(
            for: content.kind, canRender: canRender, showingSource: showingSource, copied: copied)
    }
}

// MARK: - SideRegionView

/// The side region of a daemon-rendered workspace tab (panel tabs spec, "The
/// renderer"): its strip, a divider, and the active panel through the shared
/// leaf view.
///
/// The strip is as tall as the workspace tab bar (`TabRowMetrics.height`, or
/// with the Tabs in the toolbar setting on the toolbar's height,
/// `MainTabRowMetrics.height`), so the two read as one row split by the
/// divider, and clipped to its frame, so it never draws over the divider. The
/// region is never narrower than the strip's fixed controls
/// (`SideStripMetrics.fixedControlsWidth`), so none of them is clipped: the
/// panel tabs between them give up room and scroll instead.
///
/// Left to right (side panel toggle pills spec, "The strip") it holds:
///
/// - **History** search, back and forward for the active panel. They are
///   always drawn and only disabled, so the tabs never shift under the
///   pointer; they are dimmed in front of a note, a transcript or the Changes
///   list, which have no history.
/// - **The tabs** (`SideRegionStrip.tabs`): files, web pages, and any note of
///   the worktree other than the first, each selecting on a click, closing
///   from its ×, offering the file menu on a right-click for a file or a
///   transcript no pill stands for, and showing its tooltip on hover. The
///   Changes panel, the first note's and the transcript's get no tab: their
///   pills stand for them.
/// - **The active panel's own control** (`SideRegionStrip.trailingControl`).
/// - **The pills**: Changes while the worktree has changes or its panel is
///   open (`TabRowEdgeControls.showsChanges`), the transcript while the
///   workspace tab bar would draw its toggle, and Notes
///   (`SidePanelPillButton`). Each opens, selects or closes its panel. The
///   transcript and Notes pills always show their panel's name, and Changes
///   is its icon alone (`TabRowEdgeItem.pillLabel`), so every control keeps
///   its place whatever the panels do. The transcript pill's right-click
///   offers the session file's menu, and the Notes pill's Delete Note… and,
///   when the worktree has other notes with no panel, Open Other Note.
/// - **Collapse**, which carries `⌘\` while the region shows.
///
/// The pills belong to the window's right edge, which the strip reaches while
/// it shows. The strip builds them with the function that builds the
/// workspace tab bar's toggles (`TabRowEdgeControls.make`), from the tab's
/// `primary` and `transcriptViewEnabled`, which the workspace view passes in
/// as plain values, so both rows decide the same three toggles and SwiftUI
/// can still tell when this view's inputs are unchanged.
///
/// A note tab is renamed in place, by a double-click or the Rename Tab item
/// its right-click offers, and the rename writes the note's title
/// (`AppState.commitSideNoteRename`). Its × closes the panel and deletes the
/// note, asking first when the note has content (`AppState.closeSidePanel`);
/// every other tab's × only closes its panel.
///
/// The leaf draws no header: the tab names and closes the panel, and the strip
/// carries its history buttons and its control. The control reads the
/// panel's `PaneChromeState` from `chromeStore`, which hands the same state to
/// the leaf. The leaf is keyed by the panel's ID, so a newly active panel gets
/// a new leaf and its own state together: a web view's coordinator keeps the
/// first `WebviewState` it is given, so one leaf must keep one state for its
/// whole life.
///
/// The Changes list has no leaf form, so it draws `ChangesPanelView` in the
/// leaf's place, keyed and handed its state the same way, with the worktree's
/// last loaded list (`AppState.changesSnapshot`) to show at once; it reads git
/// again on appearing only when that list is missing or old. Its control is
/// `PaneRefreshControl`, a spinner while the list loads. A click on one of
/// its files opens the file here (`ChangesPanelClick`), in a new panel when
/// Shift is held.
///
/// History steps go out as panel operations through the active panel's
/// daemon action set. The render toggle, copy-address and refresh act on the
/// chrome state and send nothing. The pills do what their toggles do at the
/// end of the workspace tab bar.
struct SideRegionView: View {
    let surface: WorkspaceTabSurface
    let worktree: LocalWorktree
    /// The workspace tab's primary as the app holds it
    /// (`PanelSurfaceWorkspaceView.primaryContent`), which decides the
    /// transcript pill.
    let primary: PaneContent
    /// Whether the transcript view setting is on, as the workspace view
    /// reads it.
    let transcriptViewEnabled: Bool
    @Environment(AppState.self) var appState

    /// Each panel's control state: its rendered/source toggle, whether its
    /// file can render, its web page's address and the copy checkmark, and
    /// the Changes list's refresh count and loading flag. Pruned
    /// to the strip's panels — the worktree's and the tab's own — as they
    /// change.
    @State private var chromeStore = PaneChromeStore()
    @State private var showHistoryPalette = false
    /// The note tab whose rename field is open, if any.
    @State private var renamingPanelID: PanelID?

    /// The active panel, with what the strip and the leaf act on for it.
    private struct ActivePanel {
        let tab: SideRegionTab
        let chrome: PaneChromeState
        let actions: PaneActions
        /// The panel's history as the palette and the chevrons show it.
        let history: PaneHistory?
    }

    var body: some View {
        let notes = appState.notes[worktree.id]
        // The same builder the workspace tab bar's toggles come from, so the
        // two rows agree; read here, so what it reads is a dependency of this
        // body.
        let edge = TabRowEdgeControls.make(
            appState: appState, worktreeID: surface.worktreeID, tabID: surface.id, primary: primary,
            surface: surface, transcriptViewEnabled: transcriptViewEnabled)
        let panels = SideRegionStrip.panels(
            for: surface,
            notes: notes,
            transcriptPath: { terminalID in
                appState.terminal(id: terminalID, in: worktree.id)?.transcriptPath
            })
        // The active panel may be one a pill stands for, so it is found among
        // every panel, not only the tabs.
        let active = panels.first(where: \.isActive).map { activePanel(for: $0) }
        let pilled = SideRegionStrip.pillPanelIDs(
            surface: surface, notes: notes, transcriptTerminalID: edge.transcriptTerminalID)
        let tabs = panels.filter { !pilled.contains($0.id) }

        VStack(spacing: 0) {
            strip(tabs: tabs, active: active, edge: edge, notes: notes)

            Divider()

            if let active, let paneContent = active.tab.paneContent {
                PanePlaceholder(
                    content: paneContent,
                    worktree: worktree,
                    tabID: surface.id,
                    actions: active.actions,
                    chrome: active.chrome
                )
                .id(active.tab.id)
            } else if let active, case .changes = active.tab.content {
                ChangesPanelView(
                    worktree: worktree,
                    chrome: active.chrome,
                    cachedSnapshot: appState.changesSnapshot(worktreeID: worktree.id),
                    onOpenFile: { relativePath, newPanel in
                        send(ChangesPanelClick.operation(
                            worktreePath: worktree.path, relativePath: relativePath, shift: newPanel))
                    }
                )
                .id(active.tab.id)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: Self.panelIDs(of: surface)) { _, panelIDs in
            chromeStore.prune(keeping: Set(panelIDs))
        }
        .onChange(of: active?.tab.id) { _, _ in
            // The palette lists one panel's history; another panel in front
            // closes it rather than show that panel's under the same anchor.
            showHistoryPalette = false
        }
    }

    /// Every panel the strip can show: the worktree's, then the tab's own.
    private static func panelIDs(of surface: WorkspaceTabSurface) -> [PanelID] {
        surface.worktreePanels.map(\.id) + surface.side.panels.map(\.id)
    }

    private func activePanel(for tab: SideRegionTab) -> ActivePanel {
        let actions = PaneActions.daemon(
            appState: appState, worktreeID: surface.worktreeID, tabID: surface.id, panelID: tab.id)
        var history: PaneHistory?
        if let paneContent = tab.paneContent {
            history = actions.history(paneContent)
        }
        return ActivePanel(
            tab: tab,
            chrome: chromeStore.state(for: tab.id),
            actions: actions,
            history: history)
    }

    // MARK: - Strip

    /// The history buttons, the tabs, the active panel's control, the pills
    /// and the collapse button. The scroll view of tabs takes the width
    /// between the two ends, which keep their full width however many tabs
    /// there are, and scrolls the active panel's tab into view when the strip
    /// appears, when another panel comes to the front and when the tabs
    /// change; a panel a pill stands for has no tab to scroll to.
    private func strip(
        tabs: [SideRegionTab], active: ActivePanel?, edge: TabRowEdgeControls, notes: [NoteSummary]?
    ) -> some View {
        ScrollViewReader { proxy in
            stripRow(tabs: tabs, active: active, edge: edge, notes: notes)
                .onAppear { scrollActiveTabIntoView(proxy) }
                .onChange(of: surface.side.activePanelID) { _, _ in scrollActiveTabIntoView(proxy) }
                .onChange(of: tabs.map(\.id)) { _, _ in scrollActiveTabIntoView(proxy) }
        }
    }

    /// The strip's row, without its scrolling. Its trailing end draws
    /// `SideStripTrailingItem.items` in the order they come, `edge`'s pills
    /// among them. The history group and the trailing group take
    /// `RowIconButtonStyle`; each pill sizes the style to itself, and the
    /// pills' context menus reset it (`pill`). The tabs, with their context
    /// menus, take no part of it.
    private func stripRow(
        tabs: [SideRegionTab], active: ActivePanel?, edge: TabRowEdgeControls, notes: [NoteSummary]?
    ) -> some View {
        let trailingItems = SideStripTrailingItem.items(
            activePanelControl: active.flatMap { activeControl($0) },
            edgeItems: edge.items)
        // With the Tabs in the toolbar setting on, the strip is the window's
        // top row over the side region: the toolbar's height, pill tabs, and
        // a drag gap in the width after the last tab.
        let chrome = appState.windowChrome
        let tabsInToolbar = chrome.tabsInToolbar
        return HStack(spacing: 0) {
            historyGroup(active: active)
                // Icon buttons only, so the style reaches no tab and no
                // context menu (`RowIconButtonStyle`).
                .buttonStyle(RowIconButtonStyle())
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)

            if tabsInToolbar {
                TabsThenDragGapLayout {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: MainTabRowMetrics.pillSpacing) {
                            ForEach(tabs) { tab in
                                tabItem(tab, pill: true)
                            }
                        }
                        // Pills hold their own height; the stack fills the
                        // row's to centre them on its midline.
                        .frame(maxHeight: .infinity)
                    }
                    WindowDragGap()
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(tabs) { tab in
                            tabItem(tab, pill: false)
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 0) {
                ForEach(trailingItems) { item in
                    trailingItem(item, active: active, edge: edge, notes: notes)
                }
            }
            // Icon buttons and pills; the pills' context menus reset the
            // style (`pill`).
            .buttonStyle(RowIconButtonStyle())
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.trailing, MainTabRowMetrics.trailingInset)
        .frame(height: tabsInToolbar
            ? MainTabRowMetrics.height(topSafeAreaInset: chrome.topSafeAreaInset)
            : TabRowMetrics.height)
        // A backstop. The workspace view keeps the region at least as wide as
        // the two fixed-width ends (`SideStripMetrics.fixedControlsWidth`,
        // `PanelSurfaceWorkspaceView.minimumSideShare`), so they fit and only
        // the panel tabs between them give up room. Only a main area too small
        // for even the widest share to hold them can leave the strip narrower
        // than its ends, and the row would then report the larger width and
        // overflow on both sides. This frame takes exactly the strip's width
        // and pins the row to its trailing edge, so what does not fit falls
        // off the leading end, the history buttons first, and the clip below
        // cuts it there, off the divider; the buttons at the window's edge
        // stay in reach. The content shape keeps clicks to the strip's frame
        // too, because a clip limits drawing, not hit testing, and the clipped
        // buttons would otherwise take clicks over the end of the workspace
        // tab bar.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        .clipped()
        .contentShape(Rectangle())
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Scrolls the strip's tabs the least distance that shows the active
    /// panel's tab whole; a tab already in view does not move.
    private func scrollActiveTabIntoView(_ proxy: ScrollViewProxy) {
        guard let activePanelID = surface.side.activePanelID else { return }
        proxy.scrollTo(activePanelID)
    }

    // MARK: History buttons

    /// Search, back and forward, acting on the active panel. Each is disabled
    /// where `SideRegionStrip.historyButtons` says it cannot act, and with no
    /// active panel all three are.
    private func historyGroup(active: ActivePanel?) -> some View {
        let enabled = active.map {
            SideRegionStrip.historyButtons(for: $0.tab.content, history: $0.history)
        } ?? SideStripHistoryButtons(search: false, back: false, forward: false)

        return HStack(spacing: 0) {
            historySearchButton(active: active)
                .disabled(!enabled.search)

            historyStepButton(icon: "chevron.left", help: "Back") {
                guard let active, let paneContent = active.tab.paneContent else { return }
                active.actions.historyStep(paneContent, .back)
            }
            .disabled(!enabled.back)

            historyStepButton(icon: "chevron.right", help: "Forward") {
                guard let active, let paneContent = active.tab.paneContent else { return }
                active.actions.historyStep(paneContent, .forward)
            }
            .disabled(!enabled.forward)
        }
        .padding(.leading, SideStripMetrics.historyLeadingInset)
    }

    /// Opens the searchable history palette over the active panel's history.
    /// Choosing an entry jumps the panel's cursor to it; choosing the entry
    /// already shown sends nothing (`PaneActions.daemon`).
    private func historySearchButton(active: ActivePanel?) -> some View {
        Button {
            showHistoryPalette = true
        } label: {
            // Regular weight, a notch larger than the chevrons: at their bold
            // weight the three bars crowd into a smudge.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .regular))
        }
        .help("Search panel history")
        .accessibilityLabel(Text("Search panel history"))
        .popover(isPresented: $showHistoryPalette, arrowEdge: .bottom) {
            if let active, let history = active.history, let paneContent = active.tab.paneContent {
                PaneHistoryPaletteView(history: history) { index in
                    active.actions.historyStep(paneContent, .jump(index))
                }
                // The strip's icon-button style stops at the palette.
                .buttonStyle(.automatic)
            }
        }
    }

    /// A back or forward chevron, in the history group's `RowIconButtonStyle`,
    /// `SideStripMetrics.historyButtonWidth` square.
    private func historyStepButton(
        icon: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
        }
        .help(help)
        .accessibilityLabel(Text(help))
    }

    // MARK: Tabs

    /// A tab: a select button over the icon and title, and a close button
    /// beside it — siblings, not nested, so each takes its own clicks. A
    /// right-click offers the file menu for file and transcript tabs, and
    /// Rename Tab alone for a note tab, which a double-click also renames.
    /// As a pill (`pill`), with the Tabs in the toolbar setting on, it draws
    /// the workspace tab bar's pill fill instead of the active tab's
    /// background and line (`SideStripTabFill`).
    @ViewBuilder
    private func tabItem(_ tab: SideRegionTab, pill: Bool) -> some View {
        let item = HStack(spacing: 0) {
            Button {
                send(.select(panelID: tab.id))
            } label: {
                HStack(spacing: 4) {
                    if let systemImage = tab.systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 10))
                            .foregroundStyle(tab.isActive ? .primary : .tertiary)
                    }
                    tabTitle(tab)
                }
                .padding(.leading, 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.tooltip)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    guard tab.noteID != nil else { return }
                    renamingPanelID = tab.id
                }
            )

            Button {
                Task {
                    await appState.closeSidePanel(
                        worktreeID: surface.worktreeID, tabID: surface.id,
                        panelID: tab.id, content: tab.content)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 2)
            .help("Close panel")
        }
        .frame(maxHeight: .infinity)
        .modifier(SideStripTabFill(isActive: tab.isActive, pill: pill))

        if tab.noteID != nil {
            item.contextMenu {
                Button("Rename Tab") {
                    renamingPanelID = tab.id
                }
            }
        } else if let paneContent = tab.paneContent {
            item.headerFileContextMenu(for: paneContent, transcriptPath: tab.transcriptPath)
        } else {
            item
        }
    }

    /// The tab's title, or, while a note tab is being renamed, its rename
    /// field. A note's rename commits a new title when the trimmed text is not
    /// blank and differs from the note's title, and nothing otherwise
    /// (`AppState.commitSideNoteRename`).
    @ViewBuilder
    private func tabTitle(_ tab: SideRegionTab) -> some View {
        let title = Text(tab.title)
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 180, alignment: .leading)
            .foregroundStyle(tab.isActive ? .primary : .secondary)

        if let noteID = tab.noteID, renamingPanelID == tab.id {
            RenameableLabel(
                text: tab.title,
                isEditing: Binding(
                    get: { renamingPanelID == tab.id },
                    set: { editing in
                        if editing {
                            renamingPanelID = tab.id
                        } else if renamingPanelID == tab.id {
                            renamingPanelID = nil
                        }
                    }
                ),
                onCommit: { text in
                    appState.commitSideNoteRename(noteID: noteID, worktreeID: worktree.id, text: text)
                },
                editorFont: .systemFont(ofSize: 11),
                selectAllOnEnterEditing: true,
                displayContent: { title }
            )
            .font(.system(size: 11))
            .frame(minWidth: 60, maxWidth: 180, alignment: .leading)
        } else {
            title
        }
    }

    // MARK: Trailing edge

    /// One item at the strip's trailing end. The active panel's control acts
    /// on that panel's chrome state, the Changes list's refresh drawing as
    /// `PaneRefreshControl`; the pills do what `edge` says (`pill`); the
    /// collapse button hides the region.
    @ViewBuilder
    private func trailingItem(
        _ item: SideStripTrailingItem, active: ActivePanel?, edge: TabRowEdgeControls,
        notes: [NoteSummary]?
    ) -> some View {
        switch item {
        case .activePanelControl(let control):
            if let active {
                if control == .refresh {
                    PaneRefreshControl(chrome: active.chrome)
                } else {
                    PaneChromeControlButton(control: control) {
                        active.chrome.perform(control, contentURL: active.tab.webURL)
                    }
                }
            }
        case .edge(let edgeItem):
            pill(edgeItem, edge: edge, notes: notes)
        case .collapse:
            SidePanelToggleButton(collapsed: false) {
                send(.setCollapsed(true))
            }
        }
    }

    /// One pill, with its right-click menu (side panel toggle pills spec,
    /// "Right-click menus"): none for Changes; the session file's menu for
    /// the transcript, as its tab had (`headerFileContextMenu`), while the
    /// pill can act and the terminal has a session file; and for Notes,
    /// `notesMenu`.
    ///
    /// The pills sit in the trailing group's `RowIconButtonStyle`, and a
    /// custom style in a context menu's environment rebuilds the open menu
    /// continuously, closing any submenu. So each menu's content resets the
    /// style with `.buttonStyle(.automatic)`: the file menu does it itself
    /// (`HeaderFileContextMenu`), and `notesMenu` here.
    @ViewBuilder
    private func pill(
        _ item: TabRowEdgeItem, edge: TabRowEdgeControls, notes: [NoteSummary]?
    ) -> some View {
        let action = edge.action(for: item)
        let button = SidePanelPillButton(item: item) {
            action()
        }
        switch item {
        case .changes:
            button
        case .transcript:
            // With no terminal the pill can act for, no path, so no menu: the
            // content's IDs matter only beside a path.
            let terminalID = edge.transcriptTerminalID
            let path = terminalID.flatMap { appState.terminal(id: $0, in: worktree.id)?.transcriptPath }
            let content = PaneContent.liveTranscript(id: surface.id, terminalID: terminalID ?? surface.id)
            button.headerFileContextMenu(for: content, transcriptPath: path)
        case .notes:
            button.contextMenu {
                notesMenu(notes: notes)
                    .buttonStyle(.automatic)
            }
        }
    }

    /// The Notes pill's menu: Delete Note…, for the worktree's first note
    /// (`PaneActions.firstNote`), disabled while there is none; then, while
    /// the worktree has notes other than the first with no panel, Open Other
    /// Note, listing each (`SideRegionStrip.otherNotes`), which opens it as a
    /// tab.
    @ViewBuilder
    private func notesMenu(notes: [NoteSummary]?) -> some View {
        let first = PaneActions.firstNote(surface: surface, notes: notes)
        let others = SideRegionStrip.otherNotes(notes: notes, surface: surface)
        Group {
            Button("Delete Note\u{2026}") {
                guard let first else { return }
                deleteNote(first.noteID)
            }
            .disabled(first == nil)
            if !others.isEmpty {
                Menu("Open Other Note") {
                    ForEach(others) { note in
                        Button(note.title) {
                            send(SideRegionStrip.openOperation(for: note))
                        }
                    }
                }
            }
        }
    }

    /// Deletes the note `noteID`, asking first when it has content, as a
    /// note tab's × does (`AppState.deleteNoteAsking`).
    private func deleteNote(_ noteID: UUID) {
        let appState = appState
        let worktreeID = surface.worktreeID
        let tabID = surface.id
        Task { @MainActor in
            await appState.deleteNoteAsking(worktreeID: worktreeID, tabID: tabID, noteID: noteID)
        }
    }

    /// The active panel's control, read from its chrome state.
    private func activeControl(_ active: ActivePanel) -> PaneChromeControl? {
        SideRegionStrip.trailingControl(
            for: active.tab.content,
            canRender: active.chrome.hasRenderableContent,
            showingSource: active.chrome.showSourceCode,
            copied: active.chrome.didCopyAddress)
    }

    private func send(_ operation: PanelOperation) {
        appState.sendPanelOperation(worktreeID: surface.worktreeID, tabID: surface.id, operation)
    }
}

// MARK: - SideStripTabFill

/// A side strip tab's fill: the active tab's background and the line under
/// it, or, as a pill (`pill`), the workspace tab bar's pill fill, which
/// follows the pointer too (`TabPillBackground`).
private struct SideStripTabFill: ViewModifier {
    let isActive: Bool
    let pill: Bool

    func body(content: Content) -> some View {
        if pill {
            content.modifier(TabPillBackground(isActive: isActive))
        } else {
            content
                .background(isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                .overlay(alignment: .bottom) {
                    if isActive {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(height: 2)
                    }
                }
        }
    }
}

// MARK: - SidePanelToggleButton

/// The button that hides or shows the side region: the strip's collapse
/// button while the region shows (`collapsed` false), and the workspace tab
/// bar's expand button while it is hidden (`collapsed` true). Either one
/// ends its row at the window's right edge, right after the Notes button.
/// Both carry `⌘\`, and at most one of them draws at a time — the collapse
/// button with the strip, only while the region shows, and the expand button
/// only while it is hidden — so the shortcut is bound once.
struct SidePanelToggleButton: View {
    /// Whether the side region is collapsed, so the button shows it.
    let collapsed: Bool
    let action: () -> Void

    /// The tooltip for a button that shows the region (`collapsed`) or hides
    /// it.
    static func help(collapsed: Bool) -> String {
        collapsed ? "Show the side panel (⌘\\)" : "Hide the side panel (⌘\\)"
    }

    var body: some View {
        // Sized, with its hover square, by the `RowIconButtonStyle` of the
        // group it sits in.
        Button(action: action) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 11))
        }
        .keyboardShortcut("\\", modifiers: .command)
        .help(Self.help(collapsed: collapsed))
    }
}
