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

    /// The content as the leaf view, and the file menu, take it.
    var paneContent: PaneContent { content.paneContent(panelID: id) }

    /// The note a note tab shows, which its rename titles and its × deletes;
    /// nil for the other kinds.
    var noteID: UUID? {
        guard case .note(let noteID) = content else { return nil }
        return noteID
    }

    /// The symbol the workspace tab bar shows for the same kind.
    var systemImage: String { content.kind.tabSystemImage }

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

enum SideRegionStrip {
    /// The strip's tabs, in the region's order. A panel with no current
    /// content — only malformed decoded data can produce one — is left out
    /// rather than drawn blank.
    static func tabs(
        for side: SideRegion,
        noteTitle: (UUID) -> String?,
        transcriptPath: (UUID) -> String?
    ) -> [SideRegionTab] {
        side.panels.compactMap { panel in
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
                isActive: panel.id == side.activePanelID,
                transcriptPath: path)
        }
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
    /// the cursor allows. A note or transcript panel has no history to step
    /// through, and neither does a panel whose history is unknown, so all
    /// three are disabled.
    static func historyButtons(for content: PanelContent, history: PaneHistory?) -> SideStripHistoryButtons {
        switch content {
        case .file, .web:
            guard let history else { break }
            return SideStripHistoryButtons(
                search: PaneHistoryPaletteButtonModel.isEnabled(entryCount: history.entries.count),
                back: history.canGoBack,
                forward: history.canGoForward)
        case .note, .transcript:
            break
        }
        return SideStripHistoryButtons(search: false, back: false, forward: false)
    }

    /// The active panel's own control, drawn before the collapse button:
    /// its kind's viewer control (`PaneChromeControl.viewerControl`), the
    /// rendered/source toggle for a file that can render and copy-address for
    /// a web page. A file that cannot render, a note and a transcript have
    /// none.
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
/// The strip is as tall as the workspace tab bar (`TabRowMetrics.height`), so
/// the two read as one row split by the divider, and clipped to its frame, so
/// it never draws over the divider. Left to right it holds history search,
/// back and forward for the active panel; the panel tabs, each selecting on a
/// click, closing from its ×, offering the file menu on a right-click for a
/// file or transcript, and showing its tooltip on hover; then, at the
/// trailing edge, the active panel's own control and the collapse button,
/// which carries `⌘\` while the region shows. The history buttons are always
/// drawn and only disabled, so the tabs never shift under the pointer.
///
/// A note tab is renamed in place, by a double-click or the Rename Tab item
/// its right-click offers, and the rename writes the note's title
/// (`AppState.renameNote`). Its × closes the panel and deletes the note,
/// asking first when the note has content (`AppState.closeSidePanel`); every
/// other tab's × only closes its panel.
///
/// The leaf draws no header: the tab names and closes the panel, and the strip
/// carries its history buttons and its control. The control reads the
/// panel's `PaneChromeState` from `chromeStore`, which hands the same state to
/// the leaf. The leaf is keyed by the panel's ID, so a newly active panel gets
/// a new leaf and its own state together: a web view's coordinator keeps the
/// first `WebviewState` it is given, so one leaf must keep one state for its
/// whole life.
///
/// History steps go out as panel operations through the active panel's
/// daemon action set. The render toggle and copy-address act on the chrome
/// state and send nothing.
struct SideRegionView: View {
    let surface: WorkspaceTabSurface
    let worktree: LocalWorktree
    @Environment(AppState.self) var appState

    /// Each panel's control state: its rendered/source toggle, whether its
    /// file can render, its web page's address and the copy checkmark. Pruned
    /// to the region's panels as they change.
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
        let tabs = SideRegionStrip.tabs(
            for: surface.side,
            noteTitle: { noteID in
                appState.notes[worktree.id]?.first(where: { $0.id == noteID })?.title
            },
            transcriptPath: { terminalID in
                appState.terminal(id: terminalID, in: worktree.id)?.transcriptPath
            })
        let active = tabs.first(where: \.isActive).map { activePanel(for: $0) }

        VStack(spacing: 0) {
            strip(tabs: tabs, active: active)

            Divider()

            if let active {
                PanePlaceholder(
                    content: active.tab.paneContent,
                    worktree: worktree,
                    tabID: surface.id,
                    actions: active.actions,
                    chrome: active.chrome
                )
                .id(active.tab.id)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: surface.side.panels.map(\.id)) { _, panelIDs in
            chromeStore.prune(keeping: Set(panelIDs))
        }
        .onChange(of: active?.tab.id) { _, _ in
            // The palette lists one panel's history; another panel in front
            // closes it rather than show that panel's under the same anchor.
            showHistoryPalette = false
        }
    }

    private func activePanel(for tab: SideRegionTab) -> ActivePanel {
        let actions = PaneActions.daemon(
            appState: appState, worktreeID: surface.worktreeID, tabID: surface.id, panelID: tab.id)
        return ActivePanel(
            tab: tab,
            chrome: chromeStore.state(for: tab.id),
            actions: actions,
            history: actions.history(tab.paneContent))
    }

    // MARK: - Strip

    /// The history buttons, the tabs, the active panel's control and the
    /// collapse button. The scroll view of tabs takes the width between the
    /// two ends, which keep their full width however many tabs there are,
    /// and scrolls the active panel's tab into view when the strip appears,
    /// when another panel comes to the front and when the tabs change.
    private func strip(tabs: [SideRegionTab], active: ActivePanel?) -> some View {
        ScrollViewReader { proxy in
            stripRow(tabs: tabs, active: active)
                .onAppear { scrollActiveTabIntoView(proxy) }
                .onChange(of: surface.side.activePanelID) { _, _ in scrollActiveTabIntoView(proxy) }
                .onChange(of: tabs.map(\.id)) { _, _ in scrollActiveTabIntoView(proxy) }
        }
    }

    /// The strip's row, without its scrolling.
    private func stripRow(tabs: [SideRegionTab], active: ActivePanel?) -> some View {
        HStack(spacing: 0) {
            historyGroup(active: active)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        tabItem(tab)
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                if let active, let control = activeControl(active) {
                    PaneChromeControlButton(control: control) {
                        active.chrome.perform(control, contentURL: active.tab.webURL)
                    }
                }

                SidePanelToggleButton(collapsed: false) {
                    send(.setCollapsed(true))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .frame(height: TabRowMetrics.height)
        // At the region's minimum width the two ends can outgrow the strip;
        // clipping keeps them off the divider.
        .clipped()
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
                guard let active else { return }
                active.actions.historyStep(active.tab.paneContent, .back)
            }
            .disabled(!enabled.back)

            historyStepButton(icon: "chevron.right", help: "Forward") {
                guard let active else { return }
                active.actions.historyStep(active.tab.paneContent, .forward)
            }
            .disabled(!enabled.forward)
        }
        .padding(.leading, 4)
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
                .frame(width: 22)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Search panel history")
        .accessibilityLabel(Text("Search panel history"))
        .popover(isPresented: $showHistoryPalette, arrowEdge: .bottom) {
            if let active, let history = active.history {
                PaneHistoryPaletteView(history: history) { index in
                    active.actions.historyStep(active.tab.paneContent, .jump(index))
                }
            }
        }
    }

    /// A back or forward chevron, 22 pt wide at the row's full height.
    private func historyStepButton(
        icon: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 22)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    // MARK: Tabs

    /// A tab: a select button over the icon and title, and a close button
    /// beside it — siblings, not nested, so each takes its own clicks. A
    /// right-click offers the file menu for file and transcript tabs, and
    /// Rename Tab alone for a note tab, which a double-click also renames.
    @ViewBuilder
    private func tabItem(_ tab: SideRegionTab) -> some View {
        let item = HStack(spacing: 0) {
            Button {
                send(.select(panelID: tab.id))
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: 10))
                        .foregroundStyle(tab.isActive ? .primary : .tertiary)
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
        .background(tab.isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            if tab.isActive {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 2)
            }
        }

        if tab.noteID != nil {
            item.contextMenu {
                Button("Rename Tab") {
                    renamingPanelID = tab.id
                }
            }
        } else {
            item.headerFileContextMenu(for: tab.paneContent, transcriptPath: tab.transcriptPath)
        }
    }

    /// The tab's title, or, while a note tab is being renamed, its rename
    /// field. A note's rename commits a new title when the trimmed text is not
    /// blank and differs from the note's title (`TabRename.noteTitle`).
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
                    commitNoteRename(noteID: noteID, text: text)
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

    private func commitNoteRename(noteID: UUID, text: String) {
        let currentTitle = appState.notes[worktree.id]?.first(where: { $0.id == noteID })?.title
        guard let title = TabRename.noteTitle(text: text, currentNoteTitle: currentTitle) else { return }
        appState.renameNote(noteID: noteID, worktreeID: worktree.id, title: title)
    }

    // MARK: Trailing edge

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

// MARK: - SidePanelToggleButton

/// The button that hides or shows the side region: the strip's collapse
/// button while the region shows (`collapsed` false), and the workspace tab
/// bar's expand button while it is collapsed (`collapsed` true). Both carry
/// `⌘\`, and at most one of them draws at a time — the collapse button with
/// the strip, only while the region shows, and the expand button only while
/// it is collapsed with panels — so the shortcut is bound once.
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
        Button(action: action) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 11))
                .frame(width: 28)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("\\", modifiers: .command)
        .help(Self.help(collapsed: collapsed))
    }
}
