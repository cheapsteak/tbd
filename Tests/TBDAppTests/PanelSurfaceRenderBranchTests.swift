import CoreGraphics
import Foundation
import Testing
import TBDShared
@testable import TBDApp

// Tier 1: deterministic, in-process state only (see `PanelTabsTestSupport`).

/// The render branch, and the view-level decisions behind the daemon renderer
/// (panel tabs spec, "The render branch" and "The renderer"): which path a
/// workspace tab takes, what the side region's strip shows, what the divider
/// sends on release, and when the expand button shows.
@Suite("Panel surface render branch")
@MainActor
struct PanelSurfaceRenderBranchTests {
    private typealias Fixture = PanelTabsFixture

    private static let pageURL = URL(string: "https://example.com/docs/page")!

    /// Seeds the copy with one surface and returns it.
    private static func seed(_ state: AppState) -> WorkspaceTabSurface {
        let worktreeID = UUID()
        let tabID = UUID()
        let surface = Fixture.surface(tabID: tabID, worktreeID: worktreeID, revision: 1)
        state.panelSurfaces = [worktreeID: [tabID: surface]]
        return surface
    }

    // MARK: - The render branch

    @Test("flag off (capabilities not fetched): legacy, even with a surface in the copy")
    func flagOffRendersLegacy() async {
        await Fixture.withState(panelTabs: nil) { state in
            #expect(!state.panelTabsActive, "precondition: the switch is off")
            let surface = Self.seed(state)
            #expect(state.workspaceRenderPath(worktreeID: surface.worktreeID, tabID: surface.id) == .legacy)
        }
    }

    @Test("flag on with no surface for the tab: legacy, never a blank tab")
    func flagOnWithoutSurfaceRendersLegacy() async {
        await Fixture.withState(panelTabs: true) { state in
            #expect(state.workspaceRenderPath(worktreeID: UUID(), tabID: UUID()) == .legacy)

            // A sibling tab of a worktree the copy does hold still falls back.
            let surface = Self.seed(state)
            #expect(state.workspaceRenderPath(worktreeID: surface.worktreeID, tabID: UUID()) == .legacy)
        }
    }

    @Test("flag on with a surface for the tab: the daemon path, carrying that surface")
    func flagOnWithSurfaceRendersDaemon() async {
        await Fixture.withState(panelTabs: true) { state in
            let surface = Self.seed(state)
            #expect(state.workspaceRenderPath(worktreeID: surface.worktreeID, tabID: surface.id)
                == .daemon(surface))
        }
    }

    @Test("the daemon reporting the flag off: legacy, even with a surface in the copy")
    func daemonFlagOffRendersLegacy() async {
        await Fixture.withState(panelTabs: false) { state in
            let surface = Self.seed(state)
            #expect(state.workspaceRenderPath(worktreeID: surface.worktreeID, tabID: surface.id) == .legacy)
        }
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

        let view = PanelSurfaceWorkspaceView(tab: tab, surface: surface, worktree: worktree)

        #expect(view.primaryContent == repointed)
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

    // MARK: - Collapse and expand

    @Test("the expand button shows only for a collapsed region that has panels")
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
}
