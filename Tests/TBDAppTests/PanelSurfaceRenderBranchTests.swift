import CoreGraphics
import Foundation
import SwiftUI
import Testing
import TBDShared
@testable import TBDApp

// Tier 1: deterministic, in-process state only (see `PanelTabsTestSupport`).

/// The render branch, and the view-level decisions behind the daemon renderer
/// (panel tabs spec, "The render branch" and "The renderer"): which path a
/// workspace tab takes, what the side region's strip shows, what the divider
/// sends on release, which control the workspace tab bar carries for the
/// selected tab, and when the expand button shows.
@Suite("Panel surface render branch")
@MainActor
struct PanelSurfaceRenderBranchTests {
    private typealias Fixture = PanelTabsFixture

    private static let pageURL = URL(string: "https://example.com/docs/page")!

    /// A workspace tab bar for a view the test never draws.
    private static func tabBar(_ trailing: TabBarTrailingItems) -> TabBar {
        TabBar(
            tabs: [], worktreeID: UUID(), activeTabIndex: .constant(0),
            onCloseTab: { _ in }, trailing: trailing)
    }

    /// Seeds the copy with one surface and returns it.
    private static func seed(_ state: AppState) -> WorkspaceTabSurface {
        let worktreeID = UUID()
        let tabID = UUID()
        let surface = Fixture.surface(tabID: tabID, worktreeID: worktreeID, revision: 1)
        state.panelSurfaces = [worktreeID: [tabID: surface]]
        return surface
    }

    // MARK: - The render branch

    @Test("a tab the last sync skipped renders legacy, even with a surface in the copy")
    func skippedTabRendersLegacy() async {
        await Fixture.withState { state in
            let surface = Self.seed(state)
            state.panelSyncSkippedTabIDs = [surface.id]

            #expect(state.workspaceRenderPath(worktreeID: surface.worktreeID, tabID: surface.id) == .legacy)
        }
    }

    @Test("a tab with a surface renders the daemon path with it")
    func surfacedTabRendersDaemon() async {
        await Fixture.withState { state in
            let surface = Self.seed(state)

            #expect(state.workspaceRenderPath(worktreeID: surface.worktreeID, tabID: surface.id)
                == .daemon(surface))
        }
    }

    @Test("a tab with no surface yet renders the daemon path with an empty side region, and keeps that path when the surface arrives")
    func surfacelessTabRendersDaemonUntilAndAfterItsSurfaceArrives() async {
        await Fixture.withState { state in
            let awaitingSurface: WorkspaceRenderPath = .daemon(nil)
            #expect(state.workspaceRenderPath(worktreeID: UUID(), tabID: UUID()) == awaitingSurface)
            // A sibling tab of a worktree the copy does hold.
            let held = Self.seed(state)
            #expect(state.workspaceRenderPath(worktreeID: held.worktreeID, tabID: UUID()) == awaitingSurface)
            let drawnSide = PanelSurfaceWorkspaceView.sideRegion(of: nil)
            #expect(drawnSide == SideRegion.empty, "with no surface the view draws an empty side region")

            let tabID = UUID()
            let before = state.workspaceRenderPath(worktreeID: held.worktreeID, tabID: tabID)
            let arrived = Fixture.surface(tabID: tabID, worktreeID: held.worktreeID, revision: 0)
            state.adoptPanelTab(arrived)
            let after = state.workspaceRenderPath(worktreeID: held.worktreeID, tabID: tabID)

            // Both are the daemon case, so `layoutContent` builds the same view
            // type at the same position with the same `.id(tab.id)`, and the
            // primary's terminal view is not rebuilt when the surface arrives.
            let arrivedPath: WorkspaceRenderPath = .daemon(arrived)
            #expect(before == awaitingSurface)
            #expect(after == arrivedPath)
        }
    }

    /// A legacy layout around `tab`'s primary with `other` beside it.
    private static func layout(around tab: TBDShared.Tab, beside other: PaneContent) -> LayoutNode {
        .split(
            id: UUID(), direction: .horizontal,
            children: [.pane(tab.content), .pane(other)],
            ratios: [0.5, 0.5])
    }

    /// The skipped set lives only in memory, so after a launch nothing names
    /// such a tab until the first sync answers; the converter's own test keeps
    /// it legacy meanwhile.
    @Test("a tab with no surface whose layout splits off a terminal renders legacy before any sync names it")
    func terminalSplitRendersLegacyBeforeAnySync() async {
        await Fixture.withState { state in
            let worktreeID = UUID()
            let tab = Fixture.terminalTab(label: "agent")
            state.tabs[worktreeID] = [tab]
            state.layouts[tab.id] = Self.layout(around: tab, beside: .terminal(terminalID: UUID()))

            #expect(state.panelSyncSkippedTabIDs.isEmpty, "precondition: no sync has named it")
            #expect(state.workspaceRenderPath(worktreeID: worktreeID, tabID: tab.id) == .legacy)
        }
    }

    @Test("a tab whose layout splits off a terminal renders the daemon path when the copy holds its surface")
    func terminalSplitWithASurfaceRendersDaemon() async {
        await Fixture.withState { state in
            let worktreeID = UUID()
            let tab = Fixture.terminalTab(label: "agent")
            state.tabs[worktreeID] = [tab]
            state.layouts[tab.id] = Self.layout(around: tab, beside: .terminal(terminalID: UUID()))
            let surface = Fixture.surface(tabID: tab.id, worktreeID: worktreeID, revision: 1)
            state.panelSurfaces = [worktreeID: [tab.id: surface]]

            let withSurface: WorkspaceRenderPath = .daemon(surface)
            #expect(state.workspaceRenderPath(worktreeID: worktreeID, tabID: tab.id) == withSurface)
        }
    }

    @Test("a tab with no surface whose layout splits off only viewers renders the daemon path with none")
    func viewerSplitRendersDaemonAwaitingSurface() async {
        await Fixture.withState { state in
            let worktreeID = UUID()
            let tab = Fixture.terminalTab(label: "agent")
            state.tabs[worktreeID] = [tab]
            state.layouts[tab.id] = Self.layout(around: tab, beside: .codeViewer(id: UUID(), path: "/w/a.md"))

            let awaitingSurface: WorkspaceRenderPath = .daemon(nil)
            #expect(state.workspaceRenderPath(worktreeID: worktreeID, tabID: tab.id) == awaitingSurface)
        }
    }

    /// The daemon skips a tab whose legacy layout holds a terminal outside the
    /// primary. Closing that terminal changes `layouts`, which offers the tab
    /// again, and the sync that imports it takes it off the skipped set.
    @Test("a skipped tab returns to the daemon path once a sync result drops it from the skipped set")
    func skippedTabReturnsToDaemonOnceASyncImportsIt() async throws {
        try await Fixture.withState { state in
            let tab = Fixture.terminalTab(label: "agent")
            let split = LayoutNode.split(
                id: UUID(), direction: .horizontal,
                children: [.pane(tab.content), .pane(.terminal(terminalID: UUID()))],
                ratios: [0.5, 0.5])
            let syncs = PanelSyncCollector()
            state.panelSyncTrigger = { @MainActor params in
                syncs.record(params)
                let stillSplit = params.tabs.contains { $0.tabID == tab.id && $0.layout == split }
                return Fixture.syncResult(skipping: stillSplit ? [tab.id] : [])
            }
            state.layouts[tab.id] = split
            let worktreeID = await Fixture.readyWorktree(state, tabs: [tab], syncs: syncs)
            try #require(state.panelSyncSkippedTabIDs == [tab.id], "precondition: the first sync skipped it")
            #expect(state.workspaceRenderPath(worktreeID: worktreeID, tabID: tab.id) == .legacy)

            // The user closes the extra terminal.
            state.layouts[tab.id] = .pane(tab.content)
            await Fixture.drainMainActor()

            #expect(syncs.sent.count == 1, "observed \(syncs.sent.map(\.worktreeID))")
            #expect(state.panelSyncSkippedTabIDs.isEmpty)
            let awaitingSurface: WorkspaceRenderPath = .daemon(nil)
            #expect(state.workspaceRenderPath(worktreeID: worktreeID, tabID: tab.id) == awaitingSurface)
        }
    }

    /// `SingleWorktreeView` draws the tab bar full width above the content on
    /// every path but the daemon one, where the workspace view draws it over
    /// the primary's column.
    @Test("only a daemon-path tab with Session History closed renders the daemon path, with or without a surface")
    func rendersDaemonPathOnlyForADaemonTabOutsideHistory() {
        let surface = Fixture.surface(tabID: UUID(), worktreeID: UUID(), revision: 1)
        let withSurface: WorkspaceRenderPath = .daemon(surface)
        let awaitingSurface: WorkspaceRenderPath = .daemon(nil)
        let skipped: WorkspaceRenderPath = .legacy

        // A daemon-path tab, with its surface or without one yet.
        #expect(SingleWorktreeView.rendersDaemonPath(historyActive: false, renderPath: withSurface))
        #expect(SingleWorktreeView.rendersDaemonPath(historyActive: false, renderPath: awaitingSurface))
        // Session History open, over the same tabs.
        #expect(!SingleWorktreeView.rendersDaemonPath(historyActive: true, renderPath: withSurface))
        #expect(!SingleWorktreeView.rendersDaemonPath(historyActive: true, renderPath: awaitingSurface))
        // No tab shown.
        #expect(!SingleWorktreeView.rendersDaemonPath(historyActive: false, renderPath: nil))
        // A tab the last tab sync skipped.
        #expect(!SingleWorktreeView.rendersDaemonPath(historyActive: false, renderPath: skipped))
    }

    // MARK: - The primary

    @Test("the primary renders the app's tab, not the surface's copy of it")
    func primaryRendersTheTabNotTheSurface() throws {
        let worktree = try #require(LocalWorktree(Worktree(
            repoID: UUID(), name: "wt", displayName: "WT", branch: "main",
            path: "/tmp/acme-wt", tmuxServer: "test-server")))
        // The file viewer has pointed the tab at a new file; the daemon's copy
        // still names the old one until a `panel.syncTabs` lands.
        let repointed = PaneContent.codeViewer(id: UUID(), path: "/w/new.swift")
        let tab = TBDShared.Tab(id: UUID(), content: repointed, label: "new.swift")
        let surface = WorkspaceTabSurface(
            id: tab.id, worktreeID: worktree.id,
            primary: .file(FileReference(path: "/w/old.swift")), revision: 3)

        let view = PanelSurfaceWorkspaceView(
            tab: tab, surface: surface, worktree: worktree, makeTabBar: Self.tabBar)
        let awaitingSurface = PanelSurfaceWorkspaceView(
            tab: tab, surface: nil, worktree: worktree, makeTabBar: Self.tabBar)

        #expect(view.primaryContent == repointed)
        #expect(awaitingSurface.primaryContent == repointed, "the primary does not wait for the surface")
    }

    // MARK: - The side region's strip

    @Test("a panel with no current content is left out of the strip")
    func panelWithoutCurrentContentIsSkipped() {
        let shown = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/w/a.md")))
        // An empty history: only malformed decoded data produces one.
        let empty = ViewerPanel(id: UUID(), history: PanelHistory())
        #expect(empty.content == nil, "precondition: the panel has no current content")
        let side = SideRegion(
            panels: [empty, shown], activePanelID: shown.id, recency: [shown.id, empty.id])

        let tabs = SideRegionStrip.tabs(for: side, noteTitle: { _ in nil }, transcriptPath: { _ in nil })

        #expect(tabs.map(\.id) == [shown.id])
    }

    @Test("each kind gets its icon and title, in the region's order, with the active one marked")
    func stripTitlesAndIconsPerKind() {
        let noteID = UUID()
        let terminalID = UUID()
        let file = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/w/src/main.swift")))
        let web = ViewerPanel(id: UUID(), content: .web(Self.pageURL))
        let note = ViewerPanel(id: UUID(), content: .note(noteID: noteID))
        let transcript = ViewerPanel(id: UUID(), content: .transcript(terminalID: terminalID))
        let side = SideRegion(
            panels: [file, web, note, transcript], activePanelID: web.id,
            recency: [web.id, file.id, note.id, transcript.id])

        let tabs = SideRegionStrip.tabs(
            for: side,
            noteTitle: { $0 == noteID ? "Plan" : nil },
            transcriptPath: { _ in nil })

        let ids: [PanelID] = [file.id, web.id, note.id, transcript.id]
        let titles = ["main.swift", "example.com", "Plan", "Transcript"]
        let icons = ["doc.text", "globe", "note.text", "text.bubble"]
        let active = [false, true, false, false]
        #expect(tabs.map(\.id) == ids)
        #expect(tabs.map(\.title) == titles)
        #expect(tabs.map(\.systemImage) == icons)
        #expect(tabs.map(\.isActive) == active)
    }

    @Test("a note with no title yet reads Note")
    func untitledNoteReadsNote() {
        let note = PanelContent.note(noteID: UUID())
        #expect(SideRegionStrip.title(for: note, noteTitle: { _ in nil }) == "Note")
        #expect(SideRegionStrip.title(for: note, noteTitle: { _ in "" }) == "Note")
    }

    @Test("file and transcript tabs carry the file menu; web and note tabs carry none")
    func fileAndTranscriptTabsCarryTheFileMenu() throws {
        let terminalID = UUID()
        let file = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/w/a.md")))
        let transcript = ViewerPanel(id: UUID(), content: .transcript(terminalID: terminalID))
        let web = ViewerPanel(id: UUID(), content: .web(Self.pageURL))
        let note = ViewerPanel(id: UUID(), content: .note(noteID: UUID()))
        let side = SideRegion(
            panels: [file, transcript, web, note], activePanelID: file.id,
            recency: [file.id, transcript.id, web.id, note.id])

        let tabs = SideRegionStrip.tabs(
            for: side,
            noteTitle: { _ in nil },
            transcriptPath: { $0 == terminalID ? "/w/session.jsonl" : nil })
        // What the tab hands `headerFileContextMenu`, resolved the same way.
        let targets = tabs.map { headerMenuTarget(for: $0.paneContent, transcriptPath: $0.transcriptPath) }

        try #require(targets.count == 4)
        #expect(targets[0] == HeaderMenuTarget(path: "/w/a.md", copyLabel: "Copy Path"))
        #expect(targets[1] == HeaderMenuTarget(path: "/w/session.jsonl", copyLabel: "Copy Conversation Path"))
        #expect(targets[2] == nil)
        #expect(targets[3] == nil)
    }

    @Test("a transcript whose terminal has no session file yet carries no menu")
    func transcriptWithoutSessionFileCarriesNoMenu() throws {
        let transcript = ViewerPanel(id: UUID(), content: .transcript(terminalID: UUID()))
        let side = SideRegion(panels: [transcript], activePanelID: transcript.id, recency: [transcript.id])

        let tabs = SideRegionStrip.tabs(for: side, noteTitle: { _ in nil }, transcriptPath: { _ in "" })

        let tab = try #require(tabs.first)
        #expect(tab.transcriptPath == nil)
        #expect(headerMenuTarget(for: tab.paneContent, transcriptPath: tab.transcriptPath) == nil)
    }

    @Test("the strip's history buttons are enabled for a file or web panel and dimmed for a transcript or note")
    func stripHistoryButtonsPerKind() {
        let panelID = UUID()
        let newer = PaneContent.codeViewer(id: panelID, path: "/w/a.md")
        let older = PaneContent.codeViewer(id: panelID, path: "/w/b.md")
        // Entries [newer, older] with the cursor on the newer one: back moves
        // toward older entries, at higher indices.
        var onNewer = PaneHistory.seeded(with: older)
        onNewer.recordReplacement(outgoing: older, incoming: newer)
        var onOlder = onNewer
        _ = onOlder.goBack()
        let entries: [PaneContent] = [newer, older]
        #expect(onNewer.entries == entries, "precondition: two entries, newest first")
        #expect(onNewer.cursor == 0)
        #expect(onOlder.cursor == 1)
        let single = PaneHistory.seeded(with: .webview(id: panelID, url: Self.pageURL))

        let file = PanelContent.file(FileReference(path: "/w/a.md"))
        let web = PanelContent.web(Self.pageURL)
        let note = PanelContent.note(noteID: UUID())
        let transcript = PanelContent.transcript(terminalID: UUID())

        let backOnly: SideStripHistoryButtons = SideStripHistoryButtons(search: true, back: true, forward: false)
        let forwardOnly: SideStripHistoryButtons = SideStripHistoryButtons(search: true, back: false, forward: true)
        let searchOnly: SideStripHistoryButtons = SideStripHistoryButtons(search: true, back: false, forward: false)
        let dimmed: SideStripHistoryButtons = SideStripHistoryButtons(search: false, back: false, forward: false)

        #expect(SideRegionStrip.historyButtons(for: file, history: onNewer) == backOnly)
        #expect(SideRegionStrip.historyButtons(for: file, history: onOlder) == forwardOnly)
        #expect(SideRegionStrip.historyButtons(for: web, history: onNewer) == backOnly)
        #expect(SideRegionStrip.historyButtons(for: web, history: single) == searchOnly)
        // A note or a transcript is dimmed, even over a history a file would
        // step through.
        #expect(SideRegionStrip.historyButtons(for: note, history: onNewer) == dimmed)
        #expect(SideRegionStrip.historyButtons(for: transcript, history: onNewer) == dimmed)
        #expect(SideRegionStrip.historyButtons(for: transcript, history: onOlder) == dimmed)
        // A file whose history is unknown has nothing to step through.
        #expect(SideRegionStrip.historyButtons(for: file, history: nil) == dimmed)
    }

    @Test("the strip's per-kind control")
    func stripTrailingControlPerKind() {
        let file = PanelContent.file(FileReference(path: "/w/README.md"))
        let web = PanelContent.web(Self.pageURL)
        let note = PanelContent.note(noteID: UUID())
        let transcript = PanelContent.transcript(terminalID: UUID())

        // A file that can render: the rendered/source toggle, showing which.
        let showingSource: PaneChromeControl? = .renderToggle(showingSource: true)
        let showingRendered: PaneChromeControl? = .renderToggle(showingSource: false)
        #expect(SideRegionStrip.trailingControl(
            for: file, canRender: true, showingSource: true, copied: false) == showingSource)
        #expect(SideRegionStrip.trailingControl(
            for: file, canRender: true, showingSource: false, copied: false) == showingRendered)
        // A file that cannot render has none.
        #expect(SideRegionStrip.trailingControl(
            for: file, canRender: false, showingSource: true, copied: true) == nil)

        // A web page: copy-address, with its checkmark after a copy, whether
        // or not anything could render.
        let copied: PaneChromeControl? = .copyAddress(copied: true)
        let notCopied: PaneChromeControl? = .copyAddress(copied: false)
        #expect(SideRegionStrip.trailingControl(
            for: web, canRender: false, showingSource: false, copied: true) == copied)
        #expect(SideRegionStrip.trailingControl(
            for: web, canRender: true, showingSource: true, copied: false) == notCopied)

        // A note and a transcript have none, whatever the inputs say.
        let withoutControl: [PanelContent] = [note, transcript]
        for content in withoutControl {
            #expect(SideRegionStrip.trailingControl(
                for: content, canRender: true, showingSource: true, copied: true) == nil, "\(content)")
        }
    }

    @Test("a web tab's tooltip is its full address; other tabs show their title")
    func stripTooltips() throws {
        let noteID = UUID()
        let file = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/w/src/main.swift")))
        let web = ViewerPanel(id: UUID(), content: .web(Self.pageURL))
        let note = ViewerPanel(id: UUID(), content: .note(noteID: noteID))
        let transcript = ViewerPanel(id: UUID(), content: .transcript(terminalID: UUID()))
        let side = SideRegion(
            panels: [file, web, note, transcript], activePanelID: file.id,
            recency: [file.id, web.id, note.id, transcript.id])

        let tabs = SideRegionStrip.tabs(
            for: side,
            noteTitle: { $0 == noteID ? "Plan" : nil },
            transcriptPath: { _ in nil })
        try #require(tabs.count == 4)

        // The web tab's title is only the host; its tooltip is the whole URL.
        #expect(tabs[1].title == "example.com")
        #expect(tabs[1].tooltip == "https://example.com/docs/page")
        // Every other tab's tooltip is its title.
        let titles = ["main.swift", "Plan", "Transcript"]
        let tooltips = [tabs[0].tooltip, tabs[2].tooltip, tabs[3].tooltip]
        #expect(tooltips == titles)
    }

    // MARK: - The divider

    @Test("the divider's shares follow the side region's width")
    func ratiosFollowTheWidth() {
        let quarter: [CGFloat] = [0.75, 0.25]
        #expect(PanelSurfaceWorkspaceView.ratios(forWidth: 0.25) == quarter)
        // Out of range or not finite, the shares follow `SideRegion.clamp`.
        #expect(PanelSurfaceWorkspaceView.ratios(forWidth: 1.5)
            == PanelSurfaceWorkspaceView.ratios(forWidth: SideRegion.widthRange.upperBound))
        #expect(PanelSurfaceWorkspaceView.ratios(forWidth: .nan)
            == PanelSurfaceWorkspaceView.ratios(forWidth: SideRegion.defaultWidth))
    }

    @Test("a released drag sends the side's share, clamped to the model's range")
    func resizeClampsToTheWidthRange() {
        let narrow: [CGFloat] = [0.95, 0.05]
        let wide: [CGFloat] = [0.02, 0.98]
        let moved: [CGFloat] = [0.75, 0.25]
        #expect(PanelSurfaceWorkspaceView.resizeOperation(ratios: narrow, currentWidth: 0.5)
            == .resize(width: SideRegion.widthRange.lowerBound))
        #expect(PanelSurfaceWorkspaceView.resizeOperation(ratios: wide, currentWidth: 0.5)
            == .resize(width: SideRegion.widthRange.upperBound))
        #expect(PanelSurfaceWorkspaceView.resizeOperation(ratios: moved, currentWidth: 0.5)
            == .resize(width: 0.25))
    }

    @Test("a non-finite share sends no resize, though the clamp would turn it into the default width")
    func nonFiniteRatioSendsNoResize() {
        for share in [CGFloat.nan, .infinity, -.infinity] {
            let ratios: [CGFloat] = [0.5, share]
            #expect(PanelSurfaceWorkspaceView.resizeOperation(ratios: ratios, currentWidth: 0.3) == nil,
                    "share \(share)")
        }
        // A finite share at the same `currentWidth` still resizes, so the nil
        // above is the guard's doing.
        #expect(PanelSurfaceWorkspaceView.resizeOperation(ratios: [0.5, 0.5], currentWidth: 0.3)
            == .resize(width: SideRegion.defaultWidth))
    }

    @Test("a release that moved nothing, or malformed shares, sends nothing")
    func resizeUnchangedSendsNothing() {
        let unmoved = PanelSurfaceWorkspaceView.ratios(forWidth: 0.4)
        #expect(PanelSurfaceWorkspaceView.resizeOperation(ratios: unmoved, currentWidth: 0.4) == nil)
        #expect(PanelSurfaceWorkspaceView.resizeOperation(ratios: [], currentWidth: 0.4) == nil)
    }

    // MARK: - Per-tab state

    /// One workspace view serves every daemon-path tab of a worktree, so the
    /// state it keeps for a tab is keyed by the tab.
    @Test("the chrome store hands out one state per ID, and a fresh one after pruning")
    func chromeStoreKeepsOneStatePerID() {
        let store = PaneChromeStore()
        let first = UUID()
        let second = UUID()

        let firstState = store.state(for: first)
        let secondState = store.state(for: second)
        #expect(store.state(for: first) === firstState, "the same ID gets the same state")
        #expect(secondState !== firstState, "another ID gets its own state")

        firstState.showSourceCode = true
        store.prune(keeping: [second])

        #expect(store.state(for: second) === secondState, "a kept ID keeps its state")
        let refreshed = store.state(for: first)
        #expect(refreshed !== firstState, "a pruned ID gets a fresh state")
        #expect(!refreshed.showSourceCode, "nothing of the pruned state carries over")
    }

    @Test("the divider shows a drag's shares only on the tab the drag was on")
    func dragSharesBelongToTheirTab() {
        let draggedTab = UUID()
        let otherTab = UUID()
        let dragged: [CGFloat] = [0.6, 0.4]
        let fromWidth: [CGFloat] = PanelSurfaceWorkspaceView.ratios(forWidth: 0.25)
        let drag = PanelSurfaceWorkspaceView.DividerDrag(tabID: draggedTab, ratios: dragged)
        let malformed = PanelSurfaceWorkspaceView.DividerDrag(tabID: draggedTab, ratios: [0.6])

        #expect(PanelSurfaceWorkspaceView.shares(drag: drag, tabID: draggedTab, width: 0.25) == dragged)
        #expect(PanelSurfaceWorkspaceView.shares(drag: drag, tabID: otherTab, width: 0.25) == fromWidth)
        #expect(PanelSurfaceWorkspaceView.shares(drag: nil, tabID: draggedTab, width: 0.25) == fromWidth)
        #expect(PanelSurfaceWorkspaceView.shares(drag: malformed, tabID: draggedTab, width: 0.25) == fromWidth)
    }

    // MARK: - The workspace tab bar

    /// `WorkspaceTabBarChrome.trailingControl` with every input off unless
    /// named.
    private static func trailingControl(
        _ primary: PaneContent,
        isClaudeTerminal: Bool = false,
        transcriptViewEnabled: Bool = false,
        transcriptOpen: Bool = false,
        canRender: Bool = false,
        showingSource: Bool = false,
        copied: Bool = false
    ) -> PaneChromeControl? {
        WorkspaceTabBarChrome.trailingControl(
            primary: primary,
            isClaudeTerminal: isClaudeTerminal,
            transcriptViewEnabled: transcriptViewEnabled,
            transcriptOpen: transcriptOpen,
            canRender: canRender,
            showingSource: showingSource,
            copied: copied)
    }

    @Test("the workspace tab bar's trailing control for each primary kind")
    func trailingControlPerPrimaryKind() {
        let terminal = PaneContent.terminal(terminalID: UUID())
        let file = PaneContent.codeViewer(id: UUID(), path: "/w/README.md")
        let web = PaneContent.webview(id: UUID(), url: Self.pageURL)
        let note = PaneContent.note(noteID: UUID())
        let transcript = PaneContent.liveTranscript(id: UUID(), terminalID: UUID())

        // A Claude terminal with the transcript view on: the transcript
        // button, on exactly while its panel exists.
        let transcriptOn: PaneChromeControl? = .transcript(isOn: true)
        let transcriptOff: PaneChromeControl? = .transcript(isOn: false)
        #expect(Self.trailingControl(
            terminal, isClaudeTerminal: true, transcriptViewEnabled: true, transcriptOpen: true)
            == transcriptOn)
        #expect(Self.trailingControl(
            terminal, isClaudeTerminal: true, transcriptViewEnabled: true, transcriptOpen: false)
            == transcriptOff)
        // The same terminal with the transcript view off has none.
        #expect(Self.trailingControl(
            terminal, isClaudeTerminal: true, transcriptViewEnabled: false, transcriptOpen: true)
            == nil)
        // A plain terminal has none, whatever the other inputs say.
        #expect(Self.trailingControl(
            terminal, isClaudeTerminal: false, transcriptViewEnabled: true, transcriptOpen: true,
            canRender: true, copied: true)
            == nil)

        // A file that can render: the rendered/source toggle, showing which.
        let showingSource: PaneChromeControl? = .renderToggle(showingSource: true)
        let showingRendered: PaneChromeControl? = .renderToggle(showingSource: false)
        #expect(Self.trailingControl(file, canRender: true, showingSource: true) == showingSource)
        #expect(Self.trailingControl(file, canRender: true, showingSource: false) == showingRendered)
        // A file that cannot render has none.
        #expect(Self.trailingControl(
            file, isClaudeTerminal: true, transcriptViewEnabled: true, canRender: false,
            showingSource: true, copied: true)
            == nil)

        // A web page: copy-address, with its checkmark after a copy.
        let copied: PaneChromeControl? = .copyAddress(copied: true)
        let notCopied: PaneChromeControl? = .copyAddress(copied: false)
        #expect(Self.trailingControl(web, copied: true) == copied)
        #expect(Self.trailingControl(web, copied: false) == notCopied)

        // A note and a transcript primary have none, whatever the inputs say.
        let withoutControl: [PaneContent] = [note, transcript]
        for primary in withoutControl {
            #expect(Self.trailingControl(
                primary, isClaudeTerminal: true, transcriptViewEnabled: true, transcriptOpen: true,
                canRender: true, showingSource: true, copied: true)
                == nil, "\(primary)")
        }
    }

    @Test("the daemon path measures the main area below its tab row and the divider")
    func mainAreaExcludesTheTabRow() {
        let rowAndDivider: CGFloat = TabRowMetrics.height + 1
        let measured = PanelSurfaceWorkspaceView.mainAreaSize(of: CGSize(width: 800, height: 600))
        let expected = CGSize(width: 800, height: 600 - rowAndDivider)
        #expect(measured == expected)
        // Shorter than the row: nothing to measure, rather than a negative height.
        let squashed = PanelSurfaceWorkspaceView.mainAreaSize(of: CGSize(width: 800, height: 10))
        #expect(squashed.height == 0)
    }

    // MARK: - Collapse and expand

    @Test("the expand button shows only while the region is collapsed and has panels")
    func expandButtonShowsOnlyWhenCollapsedWithPanels() {
        let panel = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/w/a.md")))
        let collapsed = SideRegion(
            panels: [panel], activePanelID: panel.id, recency: [panel.id], collapsed: true)
        let expanded = SideRegion(panels: [panel], activePanelID: panel.id, recency: [panel.id])
        let emptyCollapsed = SideRegion(collapsed: true)

        #expect(PanelSurfaceWorkspaceView.showsExpandButton(side: collapsed))
        #expect(!PanelSurfaceWorkspaceView.showsExpandButton(side: expanded))
        #expect(!PanelSurfaceWorkspaceView.showsExpandButton(side: emptyCollapsed))
        #expect(!PanelSurfaceWorkspaceView.showsExpandButton(side: .empty))
    }

    /// `⌘\` is bound on the expand button in the workspace tab bar and on the
    /// collapse button in the side region's strip, which draws while the region
    /// is visible. Shown together, the shortcut would fire one of them
    /// arbitrarily.
    @Test("the expand and collapse buttons never show together")
    func expandAndCollapseNeverShowTogether() {
        let panel = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/w/a.md")))
        let empty: SideRegion = .empty
        let emptyCollapsed: SideRegion = SideRegion(collapsed: true)
        let panels: SideRegion = SideRegion(panels: [panel], activePanelID: panel.id, recency: [panel.id])
        let panelsCollapsed: SideRegion = SideRegion(
            panels: [panel], activePanelID: panel.id, recency: [panel.id], collapsed: true)
        let regions: [SideRegion] = [empty, emptyCollapsed, panels, panelsCollapsed]

        for side in regions {
            let showsExpand = PanelSurfaceWorkspaceView.showsExpandButton(side: side)
            let showsCollapse = side.isVisible
            let both = showsExpand && showsCollapse
            #expect(!both, "\(side)")
        }
        // Each button does show for one of the four, so the check above is
        // not satisfied by a button that never shows.
        #expect(PanelSurfaceWorkspaceView.showsExpandButton(side: panelsCollapsed))
        #expect(panels.isVisible)
    }
}
