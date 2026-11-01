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

/// One item of the side strip's + menu: a new note, the Changes list, or a
/// note of the worktree that no panel shows yet.
enum SideStripAddItem: Hashable, Identifiable {
    case newNote
    case changes
    case note(id: UUID, title: String)

    /// Stable across rebuilds of the menu: a note's is its ID, so a renamed
    /// note keeps its item.
    var id: String {
        switch self {
        case .newNote: return "new-note"
        case .changes: return "changes"
        case .note(let id, _): return "note-\(id.uuidString)"
        }
    }

    /// The item's text in the menu.
    var title: String {
        switch self {
        case .newNote: return "New Note"
        case .changes: return "Changes"
        case .note(_, let title): return title
        }
    }

    /// The item's symbol: a listed note and the Changes list take the icon
    /// their tab shows.
    var systemImage: String {
        switch self {
        case .newNote: return "square.and.pencil"
        case .changes: return PanelKind.changes.tabSystemImage
        case .note: return PanelKind.note.tabSystemImage
        }
    }
}

enum SideRegionStrip {
    /// The strip's tabs: the worktree's panels first, in the worktree's
    /// order, then the tab's own panels, in the region's order. An own panel
    /// with no current content — only malformed decoded data can produce one
    /// — is left out rather than drawn blank.
    static func tabs(
        for surface: WorkspaceTabSurface,
        noteTitle: (UUID) -> String?,
        transcriptPath: (UUID) -> String?
    ) -> [SideRegionTab] {
        let activePanelID = surface.side.activePanelID
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

    /// The + menu's items: New Note and Changes, then every note in `notes`
    /// that no worktree panel shows, in `notes` order, titled as its tab
    /// would be — an untitled note reads "Note". Changes is always offered:
    /// choosing it while its panel is open brings that panel forward.
    static func addMenuItems(notes: [NoteSummary], worktreePanels: [WorktreePanel]) -> [SideStripAddItem] {
        var shownNoteIDs = Set<UUID>()
        for panel in worktreePanels {
            if case .note(let noteID) = panel.content {
                shownNoteIDs.insert(noteID)
            }
        }
        let unshown = notes.filter { !shownNoteIDs.contains($0.id) }.map { note in
            SideStripAddItem.note(
                id: note.id,
                title: title(for: .note(noteID: note.id), noteTitle: { _ in note.title }))
        }
        return [.newNote, .changes] + unshown
    }

    /// The panel operation a + menu item sends: `open` for the Changes list
    /// or a listed note, which the daemon shows as a worktree panel. Nil for
    /// New Note, which first creates the note (`AppState.createNote`).
    static func addMenuOperation(for item: SideStripAddItem) -> PanelOperation? {
        switch item {
        case .newNote:
            return nil
        case .changes:
            return .open(content: .changes, newPanel: false)
        case .note(let id, _):
            return .open(content: .note(noteID: id), newPanel: false)
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

    /// The active panel's own control, drawn before the collapse button:
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
/// The strip is as tall as the workspace tab bar (`TabRowMetrics.height`), so
/// the two read as one row split by the divider, and clipped to its frame, so
/// it never draws over the divider. Left to right it holds history search,
/// back and forward for the active panel; the panel tabs — the worktree's
/// panels (notes and the Changes list), which every workspace tab of the
/// worktree shows, then this tab's own — each selecting on a click, closing
/// from its ×, offering the file menu on a right-click for a file or
/// transcript, and showing its tooltip on hover; then, at the trailing edge,
/// the + menu, the active panel's own control and the collapse button, which
/// carries `⌘\` while the region shows. The history buttons are always drawn
/// and only disabled, so the tabs never shift under the pointer; they are
/// dimmed in front of a note or the Changes list, which have no history.
///
/// The + menu offers New Note, which creates a note and shows it here
/// (`AppState.createNote`); Changes; and every note of the worktree that no
/// panel shows (`SideRegionStrip.addMenuItems`), each of which it opens.
///
/// A note tab is renamed in place, by a double-click or the Rename Tab item
/// its right-click offers, and the rename writes the note's title
/// (`AppState.commitSideNoteRename`). Its × closes the panel and deletes the
/// note, asking first when the note has content (`AppState.closeSidePanel`);
/// every other tab's ×, the Changes list's included, only closes its panel.
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
/// last loaded list (`AppState.changesSnapshot`) to show while it loads. Its
/// control is `PaneRefreshControl`, a spinner while the list loads. A click
/// on one of its files opens the file here (`ChangesPanelClick`), in a new
/// panel when Shift is held.
///
/// History steps go out as panel operations through the active panel's
/// daemon action set. The render toggle, copy-address and refresh act on the
/// chrome state and send nothing.
struct SideRegionView: View {
    let surface: WorkspaceTabSurface
    let worktree: LocalWorktree
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
        let tabs = SideRegionStrip.tabs(
            for: surface,
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

    /// The history buttons, the tabs, the + menu, the active panel's control
    /// and the collapse button. The scroll view of tabs takes the width
    /// between the two ends, which keep their full width however many tabs
    /// there are, and scrolls the active panel's tab into view when the strip
    /// appears, when another panel comes to the front and when the tabs
    /// change.
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
                addMenu

                if let active, let control = activeControl(active) {
                    if control == .refresh {
                        PaneRefreshControl(chrome: active.chrome)
                    } else {
                        PaneChromeControlButton(control: control) {
                            active.chrome.perform(control, contentURL: active.tab.webURL)
                        }
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
            if let active, let history = active.history, let paneContent = active.tab.paneContent {
                PaneHistoryPaletteView(history: history) { index in
                    active.actions.historyStep(paneContent, .jump(index))
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

    /// The + menu (`SideRegionStrip.addMenuItems`): New Note and Changes,
    /// then, below a divider, the worktree's notes that no panel shows. It is
    /// keyed by its items, so a changed note list always reaches the menu
    /// AppKit builds.
    private var addMenu: some View {
        let items = SideRegionStrip.addMenuItems(
            notes: appState.notes[worktree.id] ?? [], worktreePanels: surface.worktreePanels)
        let fixed = items.filter { !Self.isListedNote($0) }
        let listed = items.filter { Self.isListedNote($0) }
        return Menu {
            ForEach(fixed) { item in
                addMenuButton(item)
            }
            if !listed.isEmpty {
                Divider()
                ForEach(listed) { item in
                    addMenuButton(item)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28)
        .frame(maxHeight: .infinity)
        .help("Add a side panel")
        .accessibilityLabel(Text("Add a side panel"))
        .id(items)
    }

    private static func isListedNote(_ item: SideStripAddItem) -> Bool {
        if case .note = item { return true }
        return false
    }

    private func addMenuButton(_ item: SideStripAddItem) -> some View {
        Button {
            chooseAddMenuItem(item)
        } label: {
            Label(item.title, systemImage: item.systemImage)
        }
    }

    /// Opens the Changes list or a listed note in this tab, or creates a note
    /// and opens it here.
    private func chooseAddMenuItem(_ item: SideStripAddItem) {
        if let operation = SideRegionStrip.addMenuOperation(for: item) {
            send(operation)
            return
        }
        let appState = appState
        let worktreeID = surface.worktreeID
        let tabID = surface.id
        Task { @MainActor in
            await appState.createNote(worktreeID: worktreeID, tabID: tabID)
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

// MARK: - SidePanelToggleButton

/// The button that hides or shows the side region: the strip's collapse
/// button while the region shows (`collapsed` false), and the workspace tab
/// bar's expand button while it is hidden (`collapsed` true). Both carry
/// `⌘\`, and at most one of them draws at a time — the collapse button with
/// the strip, only while the region shows, and the expand button only while
/// it is hidden — so the shortcut is bound once.
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
