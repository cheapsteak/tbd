import CoreGraphics
import Foundation
import Observation
import SwiftUI
import Testing
import TBDShared
@testable import TBDApp

// Tier 1: deterministic, in-process state only (see `PanelTabsTestSupport`).

/// The render branch, and the view-level decisions behind the daemon renderer
/// (panel tabs spec, "The render branch" and "The renderer"): which path a
/// workspace tab takes, what the side region's strip shows — the worktree's
/// panels, then the tab's own — and what its + menu offers, what the divider
/// sends on release, which control the workspace tab bar carries for the
/// selected tab, and when the expand button shows and what it sends.
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

    /// A workspace tab's surface around `side`, carrying `worktreePanels`.
    private static func surface(
        side: SideRegion, worktreePanels: [WorktreePanel] = []
    ) -> WorkspaceTabSurface {
        let tabID = UUID()
        return WorkspaceTabSurface(
            id: tabID, worktreeID: UUID(), primary: .terminal(terminalID: tabID),
            side: side, worktreePanels: worktreePanels, revision: 1)
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

    /// The converter also skips a tab whose conversion the surface model
    /// cannot hold — two panes on one terminal's transcript — and the render
    /// branch asks for its whole verdict, not just the terminal test.
    @Test("a tab with no surface whose layout holds two panes on one transcript renders legacy before any sync names it")
    func duplicateTranscriptRendersLegacyBeforeAnySync() async {
        await Fixture.withState { state in
            let worktreeID = UUID()
            let tab = Fixture.terminalTab(label: "agent")
            state.tabs[worktreeID] = [tab]
            state.layouts[tab.id] = .split(
                id: UUID(), direction: .horizontal,
                children: [
                    .pane(tab.content),
                    .pane(.liveTranscript(id: UUID(), terminalID: tab.id)),
                    .pane(.liveTranscript(id: UUID(), terminalID: tab.id)),
                ],
                ratios: [0.4, 0.3, 0.3])

            #expect(state.panelSyncSkippedTabIDs.isEmpty, "precondition: no sync has named it")
            #expect(state.workspaceRenderPath(worktreeID: worktreeID, tabID: tab.id) == .legacy)
        }
    }

    @Test("a tab with no surface whose layout holds one pane on its transcript renders the daemon path with none")
    func singleTranscriptRendersDaemonAwaitingSurface() async {
        await Fixture.withState { state in
            let worktreeID = UUID()
            let tab = Fixture.terminalTab(label: "agent")
            state.tabs[worktreeID] = [tab]
            state.layouts[tab.id] = Self.layout(
                around: tab, beside: .liveTranscript(id: UUID(), terminalID: tab.id))

            let awaitingSurface: WorkspaceRenderPath = .daemon(nil)
            #expect(state.workspaceRenderPath(worktreeID: worktreeID, tabID: tab.id) == awaitingSurface)
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

    /// `SingleWorktreeView.body` asks the render branch for its shown tab, so
    /// the converter's verdict must not make that body depend on the pane
    /// histories. `convert` reads one only to build a panel's history, which
    /// it filters to the pane's kind and points at the pane's content, so no
    /// history can change whether it skips a tab.
    @Test("the converter's verdict for a tab with no surface neither reads nor follows the pane histories")
    func converterVerdictIgnoresPaneHistories() async {
        await Fixture.withState { state in
            let worktreeID = UUID()
            let skipped = Fixture.terminalTab(label: "agent")
            let converted = Fixture.terminalTab(label: "shell")
            let extraTerminal = PaneContent.terminal(terminalID: UUID())
            let viewer = PaneContent.codeViewer(id: UUID(), path: "/w/a.md")
            state.tabs[worktreeID] = [skipped, converted]
            state.layouts[skipped.id] = Self.layout(around: skipped, beside: extraTerminal)
            state.layouts[converted.id] = Self.layout(around: converted, beside: viewer)
            let legacy: WorkspaceRenderPath = .legacy
            let awaitingSurface: WorkspaceRenderPath = .daemon(nil)
            #expect(state.workspaceRenderPath(worktreeID: worktreeID, tabID: skipped.id) == legacy)
            #expect(state.workspaceRenderPath(worktreeID: worktreeID, tabID: converted.id) == awaitingSurface)

            // `onChange` is `@Sendable`, so the count lives in a reference box.
            let readerNotified = BodyEvaluationCounter()
            withObservationTracking {
                _ = state.workspaceRenderPath(worktreeID: worktreeID, tabID: skipped.id)
                _ = state.workspaceRenderPath(worktreeID: worktreeID, tabID: converted.id)
            } onChange: {
                MainActor.assumeIsolated { _ = readerNotified.bump() }
            }
            // A history of mixed kinds, among them the converted tab's own
            // transcript, behind each pane beside a primary.
            var history = PaneHistory()
            history.recordReplacement(
                outgoing: .liveTranscript(id: viewer.paneID, terminalID: converted.id),
                incoming: .webview(id: viewer.paneID, url: Self.pageURL))
            history.recordReplacement(outgoing: .webview(id: viewer.paneID, url: Self.pageURL), incoming: viewer)
            state.paneHistories = [viewer.paneID: history, extraTerminal.paneID: history]

            #expect(readerNotified.count == 0, "a pane history write notified a reader of the render branch")
            #expect(state.workspaceRenderPath(worktreeID: worktreeID, tabID: skipped.id) == legacy)
            #expect(state.workspaceRenderPath(worktreeID: worktreeID, tabID: converted.id) == awaitingSurface)
        }
    }

    /// The verdict is remembered per tab with the content and layout it was
    /// computed from; a change to either computes it again.
    @Test("the converter's verdict follows a change to the tab's layout or to its content")
    func converterVerdictFollowsLayoutAndContent() async {
        await Fixture.withState { state in
            let worktreeID = UUID()
            let tab = Fixture.terminalTab(label: "agent")
            let viewer = PaneContent.codeViewer(id: UUID(), path: "/w/a.md")
            let terminalSplit = Self.layout(around: tab, beside: .terminal(terminalID: UUID()))
            let viewerSplit = Self.layout(around: tab, beside: viewer)
            let legacy: WorkspaceRenderPath = .legacy
            let awaitingSurface: WorkspaceRenderPath = .daemon(nil)
            state.tabs[worktreeID] = [tab]
            state.layouts[tab.id] = terminalSplit
            #expect(state.workspaceRenderPath(worktreeID: worktreeID, tabID: tab.id) == legacy)

            // The extra terminal closes.
            state.layouts[tab.id] = .pane(tab.content)
            #expect(state.workspaceRenderPath(worktreeID: worktreeID, tabID: tab.id) == awaitingSurface)
            state.layouts[tab.id] = terminalSplit
            #expect(state.workspaceRenderPath(worktreeID: worktreeID, tabID: tab.id) == legacy)

            // Over one layout, re-pointing the primary from the terminal to
            // the viewer beside it leaves that terminal outside the primary.
            state.layouts[tab.id] = viewerSplit
            #expect(state.workspaceRenderPath(worktreeID: worktreeID, tabID: tab.id) == awaitingSurface)
            state.tabs[worktreeID]?[0].content = viewer
            #expect(state.workspaceRenderPath(worktreeID: worktreeID, tabID: tab.id) == legacy)
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
            tab: tab, surface: surface, worktree: worktree, tabIDs: [tab.id],
            showsPreSessionBanner: false, makeTabBar: Self.tabBar)
        let awaitingSurface = PanelSurfaceWorkspaceView(
            tab: tab, surface: nil, worktree: worktree, tabIDs: [tab.id],
            showsPreSessionBanner: false, makeTabBar: Self.tabBar)

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

        let tabs = SideRegionStrip.tabs(
            for: Self.surface(side: side), noteTitle: { _ in nil }, transcriptPath: { _ in nil })

        #expect(tabs.map(\.id) == [shown.id])
    }

    @Test("each kind gets its icon and title, in the strip's order, with the active one marked")
    func stripTitlesAndIconsPerKind() {
        let noteID = UUID()
        let terminalID = UUID()
        let note = WorktreePanel(id: UUID(), content: .note(noteID: noteID))
        let changes = WorktreePanel(id: UUID(), content: .changes)
        let file = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/w/src/main.swift")))
        let web = ViewerPanel(id: UUID(), content: .web(Self.pageURL))
        let transcript = ViewerPanel(id: UUID(), content: .transcript(terminalID: terminalID))
        let side = SideRegion(
            panels: [file, web, transcript], activePanelID: web.id,
            recency: [web.id, file.id, transcript.id])

        let tabs = SideRegionStrip.tabs(
            for: Self.surface(side: side, worktreePanels: [note, changes]),
            noteTitle: { $0 == noteID ? "Plan" : nil },
            transcriptPath: { _ in nil })

        let ids: [PanelID] = [note.id, changes.id, file.id, web.id, transcript.id]
        let titles = ["Plan", "Changes", "main.swift", "example.com", "Transcript"]
        let icons = ["note.text", "plus.forwardslash.minus", "doc.text", "globe", "text.bubble"]
        let active = [false, false, false, true, false]
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

    @Test("file and transcript tabs carry the file menu; web, note and Changes tabs carry none")
    func fileAndTranscriptTabsCarryTheFileMenu() throws {
        let terminalID = UUID()
        let note = WorktreePanel(id: UUID(), content: .note(noteID: UUID()))
        let changes = WorktreePanel(id: UUID(), content: .changes)
        let file = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/w/a.md")))
        let transcript = ViewerPanel(id: UUID(), content: .transcript(terminalID: terminalID))
        let web = ViewerPanel(id: UUID(), content: .web(Self.pageURL))
        let side = SideRegion(
            panels: [file, transcript, web], activePanelID: file.id,
            recency: [file.id, transcript.id, web.id])

        let tabs = SideRegionStrip.tabs(
            for: Self.surface(side: side, worktreePanels: [note, changes]),
            noteTitle: { _ in nil },
            transcriptPath: { $0 == terminalID ? "/w/session.jsonl" : nil })
        // What the tab hands `headerFileContextMenu`, resolved the same way;
        // a tab with no leaf content gets no menu, as `SideRegionView` does.
        let targets: [HeaderMenuTarget?] = tabs.map { tab in
            tab.paneContent.flatMap { headerMenuTarget(for: $0, transcriptPath: tab.transcriptPath) }
        }

        try #require(targets.count == 5)
        #expect(targets[0] == nil, "a note")
        #expect(targets[1] == nil, "the Changes list")
        #expect(targets[2] == HeaderMenuTarget(path: "/w/a.md", copyLabel: "Copy Path"))
        #expect(targets[3] == HeaderMenuTarget(path: "/w/session.jsonl", copyLabel: "Copy Conversation Path"))
        #expect(targets[4] == nil, "a web page")
    }

    @Test("a transcript whose terminal has no session file yet carries no menu")
    func transcriptWithoutSessionFileCarriesNoMenu() throws {
        let transcript = ViewerPanel(id: UUID(), content: .transcript(terminalID: UUID()))
        let side = SideRegion(panels: [transcript], activePanelID: transcript.id, recency: [transcript.id])

        let tabs = SideRegionStrip.tabs(
            for: Self.surface(side: side), noteTitle: { _ in nil }, transcriptPath: { _ in "" })

        let tab = try #require(tabs.first)
        let paneContent = try #require(tab.paneContent)
        #expect(tab.transcriptPath == nil)
        #expect(headerMenuTarget(for: paneContent, transcriptPath: tab.transcriptPath) == nil)
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
        let changes = PanelContent.changes

        let backOnly: SideStripHistoryButtons = SideStripHistoryButtons(search: true, back: true, forward: false)
        let forwardOnly: SideStripHistoryButtons = SideStripHistoryButtons(search: true, back: false, forward: true)
        let searchOnly: SideStripHistoryButtons = SideStripHistoryButtons(search: true, back: false, forward: false)
        let dimmed: SideStripHistoryButtons = SideStripHistoryButtons(search: false, back: false, forward: false)

        #expect(SideRegionStrip.historyButtons(for: file, history: onNewer) == backOnly)
        #expect(SideRegionStrip.historyButtons(for: file, history: onOlder) == forwardOnly)
        #expect(SideRegionStrip.historyButtons(for: web, history: onNewer) == backOnly)
        #expect(SideRegionStrip.historyButtons(for: web, history: single) == searchOnly)
        // A note, a transcript or the Changes list is dimmed, even over a
        // history a file would step through.
        #expect(SideRegionStrip.historyButtons(for: note, history: onNewer) == dimmed)
        #expect(SideRegionStrip.historyButtons(for: transcript, history: onNewer) == dimmed)
        #expect(SideRegionStrip.historyButtons(for: transcript, history: onOlder) == dimmed)
        #expect(SideRegionStrip.historyButtons(for: changes, history: onNewer) == dimmed)
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

        // The Changes list: refresh, whatever the inputs say.
        let refresh: PaneChromeControl? = .refresh
        #expect(SideRegionStrip.trailingControl(
            for: .changes, canRender: false, showingSource: false, copied: false) == refresh)
        #expect(SideRegionStrip.trailingControl(
            for: .changes, canRender: true, showingSource: true, copied: true) == refresh)

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
        let note = WorktreePanel(id: UUID(), content: .note(noteID: noteID))
        let file = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/w/src/main.swift")))
        let web = ViewerPanel(id: UUID(), content: .web(Self.pageURL))
        let transcript = ViewerPanel(id: UUID(), content: .transcript(terminalID: UUID()))
        let side = SideRegion(
            panels: [file, web, transcript], activePanelID: file.id,
            recency: [file.id, web.id, transcript.id])

        let tabs = SideRegionStrip.tabs(
            for: Self.surface(side: side, worktreePanels: [note]),
            noteTitle: { $0 == noteID ? "Plan" : nil },
            transcriptPath: { _ in nil })
        try #require(tabs.count == 4)

        // The web tab's title is only the host; its tooltip is the whole URL.
        #expect(tabs[2].title == "example.com")
        #expect(tabs[2].tooltip == "https://example.com/docs/page")
        // Every other tab's tooltip is its title.
        let titles = ["Plan", "main.swift", "Transcript"]
        let tooltips = [tabs[0].tooltip, tabs[1].tooltip, tabs[3].tooltip]
        #expect(tooltips == titles)
    }

    // MARK: - Worktree panels in the strip

    @Test("the strip lists the worktree's panels first, in their order, then the tab's own")
    func stripListsWorktreePanelsFirst() throws {
        let firstNoteID = UUID()
        let secondNoteID = UUID()
        let terminalID = UUID()
        let changes = WorktreePanel(id: UUID(), content: .changes)
        let firstNote = WorktreePanel(id: UUID(), content: .note(noteID: firstNoteID))
        let secondNote = WorktreePanel(id: UUID(), content: .note(noteID: secondNoteID))
        let file = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/w/a.md")))
        let transcript = ViewerPanel(id: UUID(), content: .transcript(terminalID: terminalID))
        // The worktree panel in front: `activePanelID` may name one.
        let side = SideRegion(
            panels: [transcript, file], activePanelID: secondNote.id,
            recency: [file.id, transcript.id])

        let tabs = SideRegionStrip.tabs(
            for: Self.surface(side: side, worktreePanels: [changes, firstNote, secondNote]),
            noteTitle: { $0 == firstNoteID ? "Plan" : nil },
            transcriptPath: { $0 == terminalID ? "/w/session.jsonl" : nil })

        let ids: [PanelID] = [changes.id, firstNote.id, secondNote.id, transcript.id, file.id]
        let worktreeWide: [Bool] = [true, true, true, false, false]
        let active: [Bool] = [false, false, true, false, false]
        let titles: [String] = ["Changes", "Plan", "Note", "Transcript", "a.md"]
        let paths: [String?] = [nil, nil, nil, "/w/session.jsonl", nil]
        try #require(tabs.count == 5)
        #expect(tabs.map(\.id) == ids)
        #expect(tabs.map(\.isWorktreeWide) == worktreeWide)
        #expect(tabs.map(\.isActive) == active)
        #expect(tabs.map(\.title) == titles)
        #expect(tabs.map(\.transcriptPath) == paths)
        #expect(tabs[1].noteID == firstNoteID, "a note tab names its note, for rename and ×")
        #expect(tabs[0].noteID == nil)

        // A tab with no worktree panels lists its own alone.
        let ownOnly = SideRegionStrip.tabs(
            for: Self.surface(side: side), noteTitle: { _ in nil }, transcriptPath: { _ in nil })
        let ownIDs: [PanelID] = [transcript.id, file.id]
        let ownWorktreeWide: [Bool] = ownOnly.map(\.isWorktreeWide)
        let expectedOwnWorktreeWide: [Bool] = [false, false]
        #expect(ownOnly.map(\.id) == ownIDs)
        #expect(ownWorktreeWide == expectedOwnWorktreeWide)
    }

    @Test("the + menu offers New Note and Changes, then exactly the notes no panel shows, in order")
    func addMenuListsExactlyNotesWithoutPanel() {
        let worktreeID = UUID()
        let shown = NoteSummary(worktreeID: worktreeID, title: "Shown")
        let untitled = NoteSummary(worktreeID: worktreeID, title: "")
        let hidden = NoteSummary(worktreeID: worktreeID, title: "Hidden")
        let panels: [WorktreePanel] = [
            WorktreePanel(id: UUID(), content: .changes),
            WorktreePanel(id: UUID(), content: .note(noteID: shown.id)),
        ]

        let items = SideRegionStrip.addMenuItems(notes: [untitled, shown, hidden], worktreePanels: panels)

        let expected: [SideStripAddItem] = [
            .newNote,
            .changes,
            .note(id: untitled.id, title: "Note"),
            .note(id: hidden.id, title: "Hidden"),
        ]
        #expect(items == expected)
        let titles: [String] = ["New Note", "Changes", "Note", "Hidden"]
        #expect(items.map(\.title) == titles)
        let distinctIDs = Set(items.map(\.id))
        #expect(distinctIDs.count == items.count, "each item has its own ID")

        // No notes, or every note shown: the two fixed items alone, Changes
        // offered even while its panel is open.
        let fixed: [SideStripAddItem] = [.newNote, .changes]
        #expect(SideRegionStrip.addMenuItems(notes: [], worktreePanels: []) == fixed)
        #expect(SideRegionStrip.addMenuItems(notes: [shown], worktreePanels: panels) == fixed)
    }

    @Test("Changes and a listed note send open; New Note sends nothing itself")
    func addMenuItemsSendOpen() {
        let noteID = UUID()
        let openChanges: PanelOperation? = .open(content: .changes, newPanel: false)
        let openNote: PanelOperation? = .open(content: .note(noteID: noteID), newPanel: false)
        #expect(SideRegionStrip.addMenuOperation(for: .changes) == openChanges)
        #expect(SideRegionStrip.addMenuOperation(for: .note(id: noteID, title: "Plan")) == openNote)
        #expect(SideRegionStrip.addMenuOperation(for: .newNote) == nil)
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

    /// On the daemon path the bar spans only the primary's column, which a
    /// wide side region leaves narrow, so its tabs can overflow it.
    @Test("the tabs keep their full width while the + button fits after them, and scroll past that")
    func tabsThenAddWidths() {
        let ideals: [CGFloat] = [300, 32]

        // Room to spare, or exactly enough: the tabs at their full width, the
        // + button right after them.
        let fits: [CGFloat] = [300, 32]
        #expect(TabsThenAddLayout.widths(idealWidths: ideals, available: 500) == fits)
        #expect(TabsThenAddLayout.widths(idealWidths: ideals, available: 332) == fits)
        // Too narrow: the tabs take what the + button leaves and scroll, and
        // the button keeps its width.
        let overflows: [CGFloat] = [168, 32]
        #expect(TabsThenAddLayout.widths(idealWidths: ideals, available: 200) == overflows)
        // Narrower than the + button itself: no width for the tabs, never a
        // negative one.
        let squeezed: [CGFloat] = [0, 32]
        #expect(TabsThenAddLayout.widths(idealWidths: ideals, available: 20) == squeezed)
        // No width offered: each at its ideal width.
        #expect(TabsThenAddLayout.widths(idealWidths: ideals, available: nil) == fits)
    }

    /// Overflowing tabs scroll, so the bar scrolls the selected one into view
    /// whenever the selection or the tab list changes.
    @Test("the bar keeps the selected tab in view, and none while Session History is open or no tab is selected")
    func selectedTabIDToKeepInView() {
        let tabs: [TBDShared.Tab] = [Fixture.terminalTab(label: "agent"), Fixture.terminalTab(label: "shell")]
        let selected = TabBar.tabIDToKeepInView(tabs: tabs, activeTabIndex: 1, isHistorySelected: false)
        let underHistory = TabBar.tabIDToKeepInView(tabs: tabs, activeTabIndex: 1, isHistorySelected: true)
        let pastTheEnd = TabBar.tabIDToKeepInView(tabs: tabs, activeTabIndex: 2, isHistorySelected: false)
        let unselected = TabBar.tabIDToKeepInView(tabs: tabs, activeTabIndex: -1, isHistorySelected: false)
        #expect(selected == tabs[1].id)
        #expect(underHistory == nil)
        #expect(pastTheEnd == nil)
        #expect(unselected == nil)
    }

    /// The height is measured at the primary leaf's slot, below the tab row,
    /// the pre-session banner while it shows, and their dividers, at whatever
    /// height those lay out; the width is the whole view's, side region
    /// included.
    @Test("the daemon path posts its full width and the primary leaf's measured height")
    func mainAreaIsTheFullWidthAndTheLeafsHeight() {
        let fullWidth: CGFloat = 800
        let leafHeight: CGFloat = 541
        let posted = PanelSurfaceWorkspaceView.mainAreaSize(width: fullWidth, primaryLeafHeight: leafHeight)
        let expected = CGSize(width: fullWidth, height: leafHeight)
        #expect(posted == expected)
    }

    // MARK: - Collapse and expand

    /// Before the copy holds a surface for the tab, the region's real state
    /// is unknown: it may be collapsed over panels, where an expand that
    /// opened Changes would be the wrong operation. So the button waits for
    /// the surface.
    @Test("the expand button shows while a loaded region is hidden, never while it shows, and not before it loads")
    func expandButtonShowsWhileHidden() {
        let panel = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/w/a.md")))
        let note = WorktreePanel(id: UUID(), content: .note(noteID: UUID()))
        let ownCollapsed = Self.surface(side: SideRegion(
            panels: [panel], activePanelID: panel.id, recency: [panel.id], collapsed: true))
        let worktreeCollapsed = Self.surface(
            side: SideRegion(activePanelID: note.id, collapsed: true), worktreePanels: [note])
        let empty = Self.surface(side: .empty)
        let emptyCollapsed = Self.surface(side: SideRegion(collapsed: true))
        let ownVisible = Self.surface(side: SideRegion(
            panels: [panel], activePanelID: panel.id, recency: [panel.id]))
        // `SideRegion.isVisible` alone would call this one hidden: it has no
        // panel of its own.
        let worktreeVisible = Self.surface(
            side: SideRegion(activePanelID: note.id), worktreePanels: [note])

        #expect(!PanelSurfaceWorkspaceView.showsExpandButton(surface: nil), "no surface yet")
        #expect(PanelSurfaceWorkspaceView.showsExpandButton(surface: empty))
        #expect(PanelSurfaceWorkspaceView.showsExpandButton(surface: emptyCollapsed))
        #expect(PanelSurfaceWorkspaceView.showsExpandButton(surface: ownCollapsed))
        #expect(PanelSurfaceWorkspaceView.showsExpandButton(surface: worktreeCollapsed))
        #expect(!PanelSurfaceWorkspaceView.showsExpandButton(surface: ownVisible))
        #expect(!PanelSurfaceWorkspaceView.showsExpandButton(surface: worktreeVisible))
    }

    @Test("expanding a region with no panel opens the Changes list")
    func expandOpensChangesOnEmptyRegion() {
        let openChanges: PanelOperation = .open(content: .changes, newPanel: false)
        #expect(PanelSurfaceWorkspaceView.expandOperation(surface: nil) == openChanges, "no surface yet")
        #expect(PanelSurfaceWorkspaceView.expandOperation(surface: Self.surface(side: .empty)) == openChanges)
        #expect(PanelSurfaceWorkspaceView.expandOperation(
            surface: Self.surface(side: SideRegion(collapsed: true))) == openChanges)
    }

    @Test("expanding a collapsed region with panels, its own or the worktree's, uncollapses it")
    func expandUncollapsesRegionWithPanels() {
        let panel = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/w/a.md")))
        let note = WorktreePanel(id: UUID(), content: .note(noteID: UUID()))
        let ownCollapsed = Self.surface(side: SideRegion(
            panels: [panel], activePanelID: panel.id, recency: [panel.id], collapsed: true))
        let worktreeCollapsed = Self.surface(
            side: SideRegion(activePanelID: note.id, collapsed: true), worktreePanels: [note])

        let uncollapse: PanelOperation = .setCollapsed(false)
        #expect(PanelSurfaceWorkspaceView.expandOperation(surface: ownCollapsed) == uncollapse)
        #expect(PanelSurfaceWorkspaceView.expandOperation(surface: worktreeCollapsed) == uncollapse)
    }

    @Test("the side panel button offers to show the region while it is collapsed, and to hide it otherwise")
    func sidePanelToggleSaysWhatItDoes() {
        #expect(SidePanelToggleButton.help(collapsed: true) == "Show the side panel (⌘\\)")
        #expect(SidePanelToggleButton.help(collapsed: false) == "Hide the side panel (⌘\\)")
    }

    /// `⌘\` is bound on the expand button in the workspace tab bar and on the
    /// collapse button in the side region's strip, which draws while the region
    /// is visible. Shown together, the shortcut would fire one of them
    /// arbitrarily; with the expand button showing whenever a loaded region is
    /// hidden, one of the two is there to take it once the surface loads.
    /// Before that, the region draws empty and neither button shows.
    @Test("exactly one of the expand and collapse buttons shows once the surface loads, and neither before")
    func expandAndCollapseNeverShowTogether() {
        let panel = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/w/a.md")))
        let note = WorktreePanel(id: UUID(), content: .note(noteID: UUID()))
        let empty = Self.surface(side: .empty)
        let emptyCollapsed = Self.surface(side: SideRegion(collapsed: true))
        let panels = Self.surface(side: SideRegion(panels: [panel], activePanelID: panel.id, recency: [panel.id]))
        let panelsCollapsed = Self.surface(side: SideRegion(
            panels: [panel], activePanelID: panel.id, recency: [panel.id], collapsed: true))
        let worktreePanels = Self.surface(side: SideRegion(activePanelID: note.id), worktreePanels: [note])
        let worktreePanelsCollapsed = Self.surface(
            side: SideRegion(activePanelID: note.id, collapsed: true), worktreePanels: [note])
        let surfaces: [WorkspaceTabSurface] = [
            empty, emptyCollapsed, panels, panelsCollapsed, worktreePanels, worktreePanelsCollapsed,
        ]

        for surface in surfaces {
            let showsExpand = PanelSurfaceWorkspaceView.showsExpandButton(surface: surface)
            // The strip, and with it the collapse button, draws exactly while
            // the region shows.
            let showsCollapse = surface.isSideVisible
            #expect(showsExpand != showsCollapse, "exactly one of the two shows: \(surface)")
        }

        // With no surface yet the view draws no side region, so the strip and
        // its collapse button do not draw, and the expand button waits too.
        #expect(!PanelSurfaceWorkspaceView.showsExpandButton(surface: nil), "neither shows before the surface loads")
    }
}
