import Foundation
import Testing
import TBDShared
@testable import TBDApp

// Tier 1: deterministic, in-process state only (see `PanelTabsTestSupport`).
// The edge controls' presses go through the stubbed `panel.apply` seam, so no
// socket opens, and every `AppState` is on a throwaway defaults suite.

/// The trailing ends of the tab row: the workspace tab bar's
/// (`TabBarTrailingItem`) and the side region's strip's
/// (`SideStripTrailingItem`). The transcript and Notes buttons
/// (`TabRowEdgeControls`) keep to the window's right edge, just before the
/// button that hides or shows the side region: in the strip while the region
/// shows, at the bar's end while it is hidden. Session History stays at the
/// bar's trailing end. With the transcript view on, the transcript button is
/// drawn on every tab, disabled in front of anything but a Claude terminal, so
/// nothing before it moves as the selection changes.
@Suite("Tab row trailing items")
@MainActor
struct TabRowTrailingTests {
    private typealias Fixture = PanelTabsFixture

    private static let pageURL = URL(string: "https://example.com/docs/page")!

    // MARK: - Controls

    private static var transcriptLive: PaneChromeControl { .transcript(isOn: false, isEnabled: true) }
    private static var transcriptOpen: PaneChromeControl { .transcript(isOn: true, isEnabled: true) }
    private static var transcriptDisabled: PaneChromeControl { .transcript(isOn: false, isEnabled: false) }
    private static var notesOff: PaneChromeControl { .notes(isOn: false, isEnabled: true) }
    private static var notesOn: PaneChromeControl { .notes(isOn: true, isEnabled: true) }
    private static var notesLoading: PaneChromeControl { .notes(isOn: false, isEnabled: false) }
    private static var renderToggle: PaneChromeControl { .renderToggle(showingSource: false) }
    private static var copyAddress: PaneChromeControl { .copyAddress(copied: false) }

    // MARK: - Fixtures

    /// A worktree in the copy holding a Claude terminal and a plain one, with
    /// its notes listed and empty, and the four primaries one workspace tab of
    /// it switches between.
    private struct World {
        let worktreeID: UUID
        let tabID: UUID
        let claudeTerminalID: UUID
        let claude: PaneContent
        let plain: PaneContent
        let file: PaneContent
        let web: PaneContent

        var primaries: [PaneContent] { [claude, plain, file, web] }
    }

    /// A Claude terminal: Claude by kind, with a session to resume, so its tab
    /// has a transcript (`Terminal.isClaudeResumable`). Idle, so the no-status
    /// mark starts no grace timer for it.
    private static func claudeTerminal(worktreeID: UUID) -> TBDShared.Terminal {
        TBDShared.Terminal(
            id: UUID(), worktreeID: worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
            claudeSessionID: "session-1", kind: .claude, activityState: .idle)
    }

    /// A plain shell terminal, which has no transcript.
    private static func plainTerminal(worktreeID: UUID) -> TBDShared.Terminal {
        TBDShared.Terminal(
            id: UUID(), worktreeID: worktreeID, tmuxWindowID: "@2", tmuxPaneID: "%2",
            kind: .shell, activityState: .idle)
    }

    private static func world(_ state: AppState) -> World {
        let worktreeID = UUID()
        let tabID = UUID()
        let claude = claudeTerminal(worktreeID: worktreeID)
        let plain = plainTerminal(worktreeID: worktreeID)
        state.terminals[worktreeID] = [claude, plain]
        state.notes[worktreeID] = []
        return World(
            worktreeID: worktreeID,
            tabID: tabID,
            claudeTerminalID: claude.id,
            claude: .terminal(terminalID: claude.id),
            plain: .terminal(terminalID: plain.id),
            file: .codeViewer(id: tabID, path: "/w/README.md"),
            web: .webview(id: tabID, url: pageURL))
    }

    /// The world's workspace tab's surface around `side`.
    private static func surface(
        _ world: World, side: SideRegion = .empty, worktreePanels: [WorktreePanel] = []
    ) -> WorkspaceTabSurface {
        WorkspaceTabSurface(
            id: world.tabID, worktreeID: world.worktreeID,
            primary: .terminal(terminalID: world.claudeTerminalID),
            side: side, worktreePanels: worktreePanels, revision: 1)
    }

    /// Seeds the copy with `surface` — none for nil — and returns the edge
    /// controls `PanelSurfaceWorkspaceView` draws for the world's tab showing
    /// `primary`.
    private static func edge(
        _ state: AppState, _ world: World, primary: PaneContent, surface: WorkspaceTabSurface?,
        transcriptViewEnabled: Bool = true
    ) -> TabRowEdgeControls {
        if let surface {
            state.panelSurfaces = [world.worktreeID: [world.tabID: surface]]
        } else {
            state.panelSurfaces = [:]
        }
        return PanelSurfaceWorkspaceView.edgeControls(
            appState: state, worktreeID: world.worktreeID, tabID: world.tabID, primary: primary,
            surface: surface, transcriptViewEnabled: transcriptViewEnabled)
    }

    /// The bar's trailing items for `primary` over `surface`, composed as
    /// `PanelSurfaceWorkspaceView` composes them, with a file that can render
    /// and every viewer control at rest.
    private static func barItems(
        primary: PaneContent, surface: WorkspaceTabSurface?, edge: TabRowEdgeControls
    ) -> [TabBarTrailingItem] {
        let viewerControl = WorkspaceTabBarChrome.viewerControl(
            primary: primary, canRender: true, showingSource: false, copied: false)
        return TabBarTrailingItems(
            viewerControl: viewerControl,
            onViewerControl: {},
            edge: edge,
            showsSide: PanelSurfaceWorkspaceView.showsSide(surface: surface),
            showsExpandButton: PanelSurfaceWorkspaceView.showsExpandButton(surface: surface),
            onExpand: {}
        ).items
    }

    /// The strip's trailing items with `activePanel` in front, composed as
    /// `SideRegionView` composes them.
    private static func stripItems(
        activePanel: PanelContent, edge: TabRowEdgeControls
    ) -> [SideStripTrailingItem] {
        SideStripTrailingItem.items(
            activePanelControl: SideRegionStrip.trailingControl(
                for: activePanel, canRender: false, showingSource: false, copied: false),
            edgeItems: edge.items)
    }

    /// What the tab row draws for one primary: the bar's items with the
    /// region loaded and hidden, and the bar's and the strip's with it showing
    /// a web page, whose copy-address is the strip's active panel control.
    private struct Row {
        let hiddenBar: [TabBarTrailingItem]
        let shownBar: [TabBarTrailingItem]
        let shownStrip: [SideStripTrailingItem]
    }

    private static func row(
        _ state: AppState, _ world: World, primary: PaneContent, transcriptViewEnabled: Bool = true
    ) -> Row {
        let hidden = surface(world)
        let hiddenEdge = edge(
            state, world, primary: primary, surface: hidden, transcriptViewEnabled: transcriptViewEnabled)
        let webPanel = ViewerPanel(id: UUID(), content: .web(pageURL))
        let shown = surface(
            world, side: SideRegion(panels: [webPanel], activePanelID: webPanel.id, recency: [webPanel.id]))
        let shownEdge = edge(
            state, world, primary: primary, surface: shown, transcriptViewEnabled: transcriptViewEnabled)
        return Row(
            hiddenBar: barItems(primary: primary, surface: hidden, edge: hiddenEdge),
            shownBar: barItems(primary: primary, surface: shown, edge: shownEdge),
            shownStrip: stripItems(activePanel: .web(pageURL), edge: shownEdge))
    }

    /// Each bar item's kind, counted from the window's right edge, whatever
    /// its control's state. Written out here rather than read from the item's
    /// `id`, so a mistake in that `id` cannot make two rows agree.
    private static func barKindsFromTheRight(_ items: [TabBarTrailingItem]) -> [String] {
        var kinds: [String] = []
        for item in items.reversed() {
            switch item {
            case .viewerControl: kinds.append("viewer control")
            case .sessionHistory: kinds.append("session history")
            case .edge(.transcript): kinds.append("transcript")
            case .edge(.notes): kinds.append("notes")
            case .expand: kinds.append("expand")
            }
        }
        return kinds
    }

    /// Each strip item's kind, counted from the window's right edge, whatever
    /// its control's state, written out for the same reason.
    private static func stripKindsFromTheRight(_ items: [SideStripTrailingItem]) -> [String] {
        var kinds: [String] = []
        for item in items.reversed() {
            switch item {
            case .addMenu: kinds.append("add menu")
            case .activePanelControl: kinds.append("active panel control")
            case .edge(.transcript): kinds.append("transcript")
            case .edge(.notes): kinds.append("notes")
            case .collapse: kinds.append("collapse")
            }
        }
        return kinds
    }

    // MARK: - The transcript button's decision

    /// `WorkspaceTabBarChrome.transcriptControl`, argument labels dropped.
    private static func transcriptControl(
        _ primary: PaneContent, isClaudeTerminal: Bool, viewEnabled: Bool, open: Bool
    ) -> PaneChromeControl? {
        WorkspaceTabBarChrome.transcriptControl(
            primary: primary,
            isClaudeTerminal: isClaudeTerminal,
            transcriptViewEnabled: viewEnabled,
            transcriptOpen: open)
    }

    @Test("the transcript button is live for a Claude terminal, disabled for every other primary, and absent with the view off")
    func transcriptControlPerPrimary() {
        let terminal = PaneContent.terminal(terminalID: UUID())
        let file = PaneContent.codeViewer(id: UUID(), path: "/w/README.md")
        let web = PaneContent.webview(id: UUID(), url: Self.pageURL)
        let note = PaneContent.note(noteID: UUID())
        let transcript = PaneContent.liveTranscript(id: UUID(), terminalID: UUID())

        // A Claude terminal with the transcript view on: live, and on exactly
        // while its panel exists.
        let open: PaneChromeControl? = Self.transcriptOpen
        let live: PaneChromeControl? = Self.transcriptLive
        #expect(Self.transcriptControl(terminal, isClaudeTerminal: true, viewEnabled: true, open: true) == open)
        #expect(Self.transcriptControl(terminal, isClaudeTerminal: true, viewEnabled: true, open: false) == live)

        // A plain or Codex terminal, and every viewer primary, with the view
        // on: drawn, disabled, and never on.
        let disabled: PaneChromeControl? = Self.transcriptDisabled
        #expect(Self.transcriptControl(terminal, isClaudeTerminal: false, viewEnabled: true, open: true) == disabled)
        let viewers: [PaneContent] = [file, web, note, transcript]
        for primary in viewers {
            #expect(Self.transcriptControl(primary, isClaudeTerminal: false, viewEnabled: true, open: false)
                == disabled, "\(primary)")
            // A stray Claude flag does not make viewer content a Claude terminal.
            #expect(Self.transcriptControl(primary, isClaudeTerminal: true, viewEnabled: true, open: true)
                == disabled, "\(primary)")
        }

        // The transcript view off: no button on any tab.
        let every: [PaneContent] = [terminal, file, web, note, transcript]
        for primary in every {
            #expect(Self.transcriptControl(primary, isClaudeTerminal: true, viewEnabled: false, open: true)
                == nil, "\(primary)")
            #expect(Self.transcriptControl(primary, isClaudeTerminal: false, viewEnabled: false, open: false)
                == nil, "\(primary)")
        }
    }

    // MARK: - The orders, as values

    @Test("the edge pair's order: the transcript button while it is drawn, then Notes")
    func edgeItemsOrder() {
        let transcript: PaneChromeControl = Self.transcriptLive
        let notes: PaneChromeControl = Self.notesOff

        let withTranscript = TabRowEdgeControls(
            transcript: transcript, onTranscript: {}, notes: notes, onNotes: {})
        let expectedWithTranscript: [TabRowEdgeItem] = [.transcript(transcript), .notes(notes)]
        #expect(withTranscript.items == expectedWithTranscript)

        let withoutTranscript = TabRowEdgeControls(
            transcript: nil, onTranscript: {}, notes: notes, onNotes: {})
        let expectedWithoutTranscript: [TabRowEdgeItem] = [.notes(notes)]
        #expect(withoutTranscript.items == expectedWithoutTranscript)
    }

    @Test("the bar ends at Session History while the region shows, and carries the edge controls and expand while it is hidden")
    func barItemsOrder() {
        let viewer: PaneChromeControl = Self.copyAddress
        let transcript: PaneChromeControl = Self.transcriptLive
        let notes: PaneChromeControl = Self.notesOff
        let edgeItems: [TabRowEdgeItem] = [.transcript(transcript), .notes(notes)]
        let notesOnly: [TabRowEdgeItem] = [.notes(notes)]

        let hidden = TabBarTrailingItem.items(
            viewerControl: viewer, edgeItems: edgeItems, showsSide: false, showsExpandButton: true)
        let expectedHidden: [TabBarTrailingItem] = [
            .viewerControl(viewer), .sessionHistory, .edge(.transcript(transcript)), .edge(.notes(notes)), .expand,
        ]
        #expect(hidden == expectedHidden)

        // Hidden without the expand button, as before the surface loads.
        let noExpand = TabBarTrailingItem.items(
            viewerControl: viewer, edgeItems: edgeItems, showsSide: false, showsExpandButton: false)
        let expectedNoExpand: [TabBarTrailingItem] = [
            .viewerControl(viewer), .sessionHistory, .edge(.transcript(transcript)), .edge(.notes(notes)),
        ]
        #expect(noExpand == expectedNoExpand)

        // No viewer control and no transcript button.
        let bare = TabBarTrailingItem.items(
            viewerControl: nil, edgeItems: notesOnly, showsSide: false, showsExpandButton: true)
        let expectedBare: [TabBarTrailingItem] = [.sessionHistory, .edge(.notes(notes)), .expand]
        #expect(bare == expectedBare)

        // Shown: the strip carries the edge controls and the collapse button,
        // so the bar ends at Session History, and never draws expand beside
        // the strip's collapse.
        let shown = TabBarTrailingItem.items(
            viewerControl: viewer, edgeItems: edgeItems, showsSide: true, showsExpandButton: true)
        let expectedShown: [TabBarTrailingItem] = [.viewerControl(viewer), .sessionHistory]
        #expect(shown == expectedShown)
        let shownBare = TabBarTrailingItem.items(
            viewerControl: nil, edgeItems: edgeItems, showsSide: true, showsExpandButton: false)
        let expectedShownBare: [TabBarTrailingItem] = [.sessionHistory]
        #expect(shownBare == expectedShownBare)
    }

    @Test("the strip ends with the + menu, the active panel's control, the edge controls and collapse")
    func stripItemsOrder() {
        let refresh: PaneChromeControl = .refresh
        let transcript: PaneChromeControl = Self.transcriptDisabled
        let notes: PaneChromeControl = Self.notesLoading
        let edgeItems: [TabRowEdgeItem] = [.transcript(transcript), .notes(notes)]
        let notesOnly: [TabRowEdgeItem] = [.notes(notes)]

        let full = SideStripTrailingItem.items(activePanelControl: refresh, edgeItems: edgeItems)
        let expectedFull: [SideStripTrailingItem] = [
            .addMenu, .activePanelControl(refresh), .edge(.transcript(transcript)), .edge(.notes(notes)), .collapse,
        ]
        #expect(full == expectedFull)

        let bare = SideStripTrailingItem.items(activePanelControl: nil, edgeItems: notesOnly)
        let expectedBare: [SideStripTrailingItem] = [.addMenu, .edge(.notes(notes)), .collapse]
        #expect(bare == expectedBare)
    }

    // MARK: - What each primary draws

    @Test("a Claude terminal: the live transcript button and Notes end the bar while the region is hidden, and the strip while it shows")
    func claudeTerminalItems() async {
        await Fixture.withState { state in
            let world = Self.world(state)
            let row = Self.row(state, world, primary: world.claude)

            let hiddenBar: [TabBarTrailingItem] = [
                .sessionHistory, .edge(.transcript(Self.transcriptLive)), .edge(.notes(Self.notesOff)), .expand,
            ]
            let shownBar: [TabBarTrailingItem] = [.sessionHistory]
            let shownStrip: [SideStripTrailingItem] = [
                .addMenu, .activePanelControl(Self.copyAddress),
                .edge(.transcript(Self.transcriptLive)), .edge(.notes(Self.notesOff)), .collapse,
            ]
            #expect(row.hiddenBar == hiddenBar)
            #expect(row.shownBar == shownBar)
            #expect(row.shownStrip == shownStrip)
        }
    }

    @Test("a plain terminal: the transcript button is drawn disabled where a Claude terminal's would be")
    func plainTerminalItems() async {
        await Fixture.withState { state in
            let world = Self.world(state)
            let row = Self.row(state, world, primary: world.plain)

            let hiddenBar: [TabBarTrailingItem] = [
                .sessionHistory, .edge(.transcript(Self.transcriptDisabled)), .edge(.notes(Self.notesOff)), .expand,
            ]
            let shownBar: [TabBarTrailingItem] = [.sessionHistory]
            let shownStrip: [SideStripTrailingItem] = [
                .addMenu, .activePanelControl(Self.copyAddress),
                .edge(.transcript(Self.transcriptDisabled)), .edge(.notes(Self.notesOff)), .collapse,
            ]
            #expect(row.hiddenBar == hiddenBar)
            #expect(row.shownBar == shownBar)
            #expect(row.shownStrip == shownStrip)
        }
    }

    @Test("a file that can render: its toggle and Session History stay in the bar, the edge controls go to the edge")
    func fileItems() async {
        await Fixture.withState { state in
            let world = Self.world(state)
            let row = Self.row(state, world, primary: world.file)

            let hiddenBar: [TabBarTrailingItem] = [
                .viewerControl(Self.renderToggle), .sessionHistory,
                .edge(.transcript(Self.transcriptDisabled)), .edge(.notes(Self.notesOff)), .expand,
            ]
            let shownBar: [TabBarTrailingItem] = [.viewerControl(Self.renderToggle), .sessionHistory]
            let shownStrip: [SideStripTrailingItem] = [
                .addMenu, .activePanelControl(Self.copyAddress),
                .edge(.transcript(Self.transcriptDisabled)), .edge(.notes(Self.notesOff)), .collapse,
            ]
            #expect(row.hiddenBar == hiddenBar)
            #expect(row.shownBar == shownBar)
            #expect(row.shownStrip == shownStrip)
        }
    }

    @Test("a web page: its copy-address and Session History stay in the bar, the edge controls go to the edge")
    func webItems() async {
        await Fixture.withState { state in
            let world = Self.world(state)
            let row = Self.row(state, world, primary: world.web)

            let hiddenBar: [TabBarTrailingItem] = [
                .viewerControl(Self.copyAddress), .sessionHistory,
                .edge(.transcript(Self.transcriptDisabled)), .edge(.notes(Self.notesOff)), .expand,
            ]
            let shownBar: [TabBarTrailingItem] = [.viewerControl(Self.copyAddress), .sessionHistory]
            let shownStrip: [SideStripTrailingItem] = [
                .addMenu, .activePanelControl(Self.copyAddress),
                .edge(.transcript(Self.transcriptDisabled)), .edge(.notes(Self.notesOff)), .collapse,
            ]
            #expect(row.hiddenBar == hiddenBar)
            #expect(row.shownBar == shownBar)
            #expect(row.shownStrip == shownStrip)
        }
    }

    @Test("a Claude terminal whose transcript panel exists draws the button on, in the strip and at the bar's end")
    func claudeTerminalWithTranscriptOpen() async {
        await Fixture.withState { state in
            let world = Self.world(state)
            let panel = ViewerPanel(id: UUID(), content: .transcript(terminalID: world.claudeTerminalID))
            let shown = Self.surface(
                world, side: SideRegion(panels: [panel], activePanelID: panel.id, recency: [panel.id]))
            let hidden = Self.surface(
                world,
                side: SideRegion(panels: [panel], activePanelID: panel.id, recency: [panel.id], collapsed: true))

            let shownEdge = Self.edge(state, world, primary: world.claude, surface: shown)
            let strip = Self.stripItems(
                activePanel: .transcript(terminalID: world.claudeTerminalID), edge: shownEdge)
            let hiddenEdge = Self.edge(state, world, primary: world.claude, surface: hidden)
            let bar = Self.barItems(primary: world.claude, surface: hidden, edge: hiddenEdge)

            // A transcript panel has no control of its own.
            let expectedStrip: [SideStripTrailingItem] = [
                .addMenu, .edge(.transcript(Self.transcriptOpen)), .edge(.notes(Self.notesOff)), .collapse,
            ]
            let expectedBar: [TabBarTrailingItem] = [
                .sessionHistory, .edge(.transcript(Self.transcriptOpen)), .edge(.notes(Self.notesOff)), .expand,
            ]
            #expect(strip == expectedStrip)
            #expect(bar == expectedBar)
        }
    }

    @Test("before the tab's surface loads the bar spans the window and carries the edge controls, with no expand button")
    func beforeTheSurfaceLoads() async {
        await Fixture.withState { state in
            let world = Self.world(state)
            let claudeEdge = Self.edge(state, world, primary: world.claude, surface: nil)
            let claude = Self.barItems(primary: world.claude, surface: nil, edge: claudeEdge)
            let plainEdge = Self.edge(state, world, primary: world.plain, surface: nil)
            let plain = Self.barItems(primary: world.plain, surface: nil, edge: plainEdge)

            let expectedClaude: [TabBarTrailingItem] = [
                .sessionHistory, .edge(.transcript(Self.transcriptLive)), .edge(.notes(Self.notesOff)),
            ]
            let expectedPlain: [TabBarTrailingItem] = [
                .sessionHistory, .edge(.transcript(Self.transcriptDisabled)), .edge(.notes(Self.notesOff)),
            ]
            #expect(claude == expectedClaude)
            #expect(plain == expectedPlain)
        }
    }

    @Test("with the transcript view off no tab draws a transcript button, in the bar or the strip")
    func transcriptViewOff() async {
        await Fixture.withState { state in
            let world = Self.world(state)
            let claude = Self.row(state, world, primary: world.claude, transcriptViewEnabled: false)
            let plain = Self.row(state, world, primary: world.plain, transcriptViewEnabled: false)
            let file = Self.row(state, world, primary: world.file, transcriptViewEnabled: false)

            let terminalHiddenBar: [TabBarTrailingItem] = [.sessionHistory, .edge(.notes(Self.notesOff)), .expand]
            let fileHiddenBar: [TabBarTrailingItem] = [
                .viewerControl(Self.renderToggle), .sessionHistory, .edge(.notes(Self.notesOff)), .expand,
            ]
            let terminalShownBar: [TabBarTrailingItem] = [.sessionHistory]
            let shownStrip: [SideStripTrailingItem] = [
                .addMenu, .activePanelControl(Self.copyAddress), .edge(.notes(Self.notesOff)), .collapse,
            ]
            #expect(claude.hiddenBar == terminalHiddenBar)
            #expect(plain.hiddenBar == terminalHiddenBar)
            #expect(file.hiddenBar == fileHiddenBar)
            #expect(claude.shownBar == terminalShownBar)
            #expect(plain.shownBar == terminalShownBar)
            #expect(claude.shownStrip == shownStrip)
            #expect(plain.shownStrip == shownStrip)
            #expect(file.shownStrip == shownStrip)
        }
    }

    @Test("the Notes button draws disabled until the notes load, and on while the first note is in front")
    func notesButtonStates() async {
        await Fixture.withState { state in
            let world = Self.world(state)
            // Not loaded, and the tab shows no note panel.
            state.notes[world.worktreeID] = nil
            let unloaded = Self.row(state, world, primary: world.claude)

            let unloadedBar: [TabBarTrailingItem] = [
                .sessionHistory, .edge(.transcript(Self.transcriptLive)), .edge(.notes(Self.notesLoading)), .expand,
            ]
            let unloadedStrip: [SideStripTrailingItem] = [
                .addMenu, .activePanelControl(Self.copyAddress),
                .edge(.transcript(Self.transcriptLive)), .edge(.notes(Self.notesLoading)), .collapse,
            ]
            #expect(unloaded.hiddenBar == unloadedBar)
            #expect(unloaded.shownStrip == unloadedStrip)

            // Loaded, with the first note in front of the visible region.
            let first = NoteSummary(worktreeID: world.worktreeID, title: "Plan")
            state.notes[world.worktreeID] = [first]
            let notePanel = WorktreePanel(id: UUID(), content: .note(noteID: first.id))
            let surface = Self.surface(
                world, side: SideRegion(activePanelID: notePanel.id), worktreePanels: [notePanel])
            let edge = Self.edge(state, world, primary: world.claude, surface: surface)
            let strip = Self.stripItems(activePanel: .note(noteID: first.id), edge: edge)

            // A note panel has no control of its own.
            let expectedStrip: [SideStripTrailingItem] = [
                .addMenu, .edge(.transcript(Self.transcriptLive)), .edge(.notes(Self.notesOn)), .collapse,
            ]
            #expect(strip == expectedStrip)
        }
    }

    // MARK: - Stable positions

    /// The reason a disabled transcript button is drawn rather than removed:
    /// switching between a Claude terminal's tab and any other moves nothing
    /// at the row's trailing end.
    @Test("the edge controls keep their places from the right edge across a Claude terminal's tab and a plain one")
    func edgeControlsKeepTheirPlaces() async {
        await Fixture.withState { state in
            let world = Self.world(state)
            let settings: [Bool] = [true, false]
            for transcriptViewEnabled in settings {
                let claude = Self.row(
                    state, world, primary: world.claude, transcriptViewEnabled: transcriptViewEnabled)
                let plain = Self.row(
                    state, world, primary: world.plain, transcriptViewEnabled: transcriptViewEnabled)

                let claudeHidden = Self.barKindsFromTheRight(claude.hiddenBar)
                let plainHidden = Self.barKindsFromTheRight(plain.hiddenBar)
                #expect(claudeHidden == plainHidden, "region hidden, transcript view \(transcriptViewEnabled)")

                let claudeShown = Self.barKindsFromTheRight(claude.shownBar)
                let plainShown = Self.barKindsFromTheRight(plain.shownBar)
                #expect(claudeShown == plainShown, "region shown, transcript view \(transcriptViewEnabled)")

                let claudeStrip = Self.stripKindsFromTheRight(claude.shownStrip)
                let plainStrip = Self.stripKindsFromTheRight(plain.shownStrip)
                #expect(claudeStrip == plainStrip, "strip, transcript view \(transcriptViewEnabled)")
            }
        }
    }

    @Test("Session History keeps its place from the right edge across every primary")
    func sessionHistoryKeepsItsPlace() async {
        await Fixture.withState { state in
            let world = Self.world(state)
            let primaries = world.primaries
            let settings: [Bool] = [true, false]
            for transcriptViewEnabled in settings {
                // Hidden: expand, Notes and, while the view is on, the
                // transcript button lie to its right.
                let hiddenIndex: Int? = transcriptViewEnabled ? 3 : 2
                // Shown: it ends the bar.
                let shownIndex: Int? = 0
                for primary in primaries {
                    let row = Self.row(state, world, primary: primary, transcriptViewEnabled: transcriptViewEnabled)
                    let hidden = Self.barKindsFromTheRight(row.hiddenBar).firstIndex(of: "session history")
                    let shown = Self.barKindsFromTheRight(row.shownBar).firstIndex(of: "session history")
                    #expect(hidden == hiddenIndex, "\(primary), transcript view \(transcriptViewEnabled)")
                    #expect(shown == shownIndex, "\(primary), transcript view \(transcriptViewEnabled)")
                }
            }
        }
    }

    // MARK: - A press

    @Test("the transcript button's press sends the transcript toggle's operation for the Claude terminal")
    func transcriptPressSendsTheToggle() async {
        await Fixture.withState { state in
            let world = Self.world(state)
            let surface = Self.surface(world)
            let edge = Self.edge(state, world, primary: world.claude, surface: surface)
            let envelopes = Fixture.collectEnvelopes(state, replying: surface)

            edge.onTranscript()
            await Fixture.drainMainActor()

            let sent: [PanelOperation] = envelopes.envelopes.map(\.operation)
            let expected: [PanelOperation] = [
                .open(content: .transcript(terminalID: world.claudeTerminalID), newPanel: false),
            ]
            #expect(sent == expected)
            let tabIDs: [UUID] = envelopes.envelopes.map(\.tabID)
            let expectedTabIDs: [UUID] = [world.tabID]
            #expect(tabIDs == expectedTabIDs)
        }
    }

    @Test("the Notes button's press sends the Notes toggle's operation for the worktree's first note")
    func notesPressSendsTheToggle() async {
        await Fixture.withState { state in
            let world = Self.world(state)
            let first = NoteSummary(
                worktreeID: world.worktreeID, title: "Plan",
                createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000))
            let second = NoteSummary(
                worktreeID: world.worktreeID, title: "Later",
                createdAt: Date(timeIntervalSince1970: 2_000), updatedAt: Date(timeIntervalSince1970: 2_000))
            state.notes[world.worktreeID] = [second, first]
            let surface = Self.surface(world)
            let edge = Self.edge(state, world, primary: world.plain, surface: surface)
            let envelopes = Fixture.collectEnvelopes(state, replying: surface)

            edge.onNotes()
            await Fixture.drainMainActor()

            let sent: [PanelOperation] = envelopes.envelopes.map(\.operation)
            let expected: [PanelOperation] = [.open(content: .note(noteID: first.id), newPanel: false)]
            #expect(sent == expected)
        }
    }

    @Test("the transcript button sends nothing while disabled, or while the transcript view is off")
    func transcriptPressSendsNothingWhenItCannotAct() async {
        await Fixture.withState { state in
            let world = Self.world(state)
            let surface = Self.surface(world)
            let envelopes = Fixture.collectEnvelopes(state, replying: surface)
            let disabled: PaneChromeControl? = Self.transcriptDisabled

            let plainEdge = Self.edge(state, world, primary: world.plain, surface: surface)
            #expect(plainEdge.transcript == disabled, "precondition: a plain terminal's button is disabled")
            plainEdge.onTranscript()

            let fileEdge = Self.edge(state, world, primary: world.file, surface: surface)
            #expect(fileEdge.transcript == disabled, "precondition: a file's button is disabled")
            fileEdge.onTranscript()

            let offEdge = Self.edge(
                state, world, primary: world.claude, surface: surface, transcriptViewEnabled: false)
            #expect(offEdge.transcript == nil, "precondition: no button with the transcript view off")
            offEdge.onTranscript()

            await Fixture.drainMainActor()

            #expect(envelopes.envelopes.isEmpty)
        }
    }
}
