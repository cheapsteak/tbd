import CoreGraphics
import Foundation
import Testing
@testable import TBDShared

/// Builders shared by `LegacyTabConverterTests` and the fixtures below.
enum LegacyTabFixture {
    static let worktreeID = UUID()

    static func file(_ path: String) -> PanelContent { .file(FileReference(path: path)) }

    static func tab(
        _ content: PaneContent, layout: LayoutNode? = nil, label: String? = nil
    ) -> LegacyTabPayload {
        LegacyTabPayload(tabID: UUID(), label: label, content: content, layout: layout)
    }

    static func hsplit(_ children: [LayoutNode], _ ratios: [CGFloat]) -> LayoutNode {
        .split(id: UUID(), direction: .horizontal, children: children, ratios: ratios)
    }

    static func vsplit(_ children: [LayoutNode], _ ratios: [CGFloat]) -> LayoutNode {
        .split(id: UUID(), direction: .vertical, children: children, ratios: ratios)
    }

    static func convert(
        _ tab: LegacyTabPayload,
        paneHistories: [UUID: MRUHistory<PaneContent>] = [:],
        makeID: () -> UUID = { UUID() }
    ) -> LegacyTabConverter.Outcome {
        LegacyTabConverter.convert(
            worktreeID: worktreeID, tab: tab, paneHistories: paneHistories, makeID: makeID)
    }

    /// The surface of a converted outcome; nil when the tab was skipped.
    static func surface(_ outcome: LegacyTabConverter.Outcome) -> WorkspaceTabSurface? {
        guard case .converted(let surface) = outcome else { return nil }
        return surface
    }
}

/// A `makeID` that records every ID it hands out, in order.
final class IDMinter {
    private(set) var minted: [UUID] = []

    func next() -> UUID {
        let id = UUID()
        minted.append(id)
        return id
    }
}

/// Legacy layouts as they exist on disk, carried through the per-tab
/// converter end to end. `LegacyTabConverterTests` covers each rule on its
/// own; these check the rules together on realistic shapes.
@Suite("LegacyTabConverter fixtures")
struct LegacyTabConverterFixtureTests {
    private typealias Fixture = LegacyTabFixture

    // MARK: - Terminal plus one viewer, the common shape

    @Test func terminalPlusViewerCarriesHistoryAndWidth() throws {
        let terminalID = UUID()
        let viewerID = UUID()
        let layout = Fixture.hsplit(
            [.pane(.terminal(terminalID: terminalID)), .pane(.codeViewer(id: viewerID, path: "/a"))],
            [0.6, 0.4])
        let tab = Fixture.tab(.terminal(terminalID: terminalID), layout: layout, label: "claude")
        let legacy = MRUHistory<PaneContent>(
            entries: [.codeViewer(id: viewerID, path: "/a"), .codeViewer(id: viewerID, path: "/b")],
            cursor: 0)
        let ids = IDMinter()

        let outcome = Fixture.convert(tab, paneHistories: [viewerID: legacy], makeID: { ids.next() })

        try #require(ids.minted.count == 1)
        let panelID = ids.minted[0]
        let history = PanelHistory(entries: [Fixture.file("/a"), Fixture.file("/b")], cursor: 0)
        let expectedWidth: Double = 0.4
        let expected = WorkspaceTabSurface(
            id: tab.tabID, worktreeID: Fixture.worktreeID, label: "claude",
            primary: .terminal(terminalID: terminalID),
            side: SideRegion(
                panels: [ViewerPanel(id: panelID, history: history)],
                activePanelID: panelID, recency: [panelID], collapsed: false, width: expectedWidth),
            revision: 0)
        #expect(outcome == .converted(expected))
        #expect(PanelSurfaceValidator.violations(in: expected).isEmpty)
    }

    // MARK: - Nested viewer splits, three deep

    @Test func nestedViewerSplitsFlattenInPreOrder() throws {
        let terminalID = UUID()
        let layout = Fixture.hsplit([
            .pane(.terminal(terminalID: terminalID)),
            Fixture.vsplit([
                .pane(.codeViewer(id: UUID(), path: "/a")),
                Fixture.hsplit(
                    [.pane(.codeViewer(id: UUID(), path: "/b")), .pane(.codeViewer(id: UUID(), path: "/c"))],
                    [0.3, 0.7]),
            ], [0.5, 0.5]),
        ], [0.6, 0.4])
        let tab = Fixture.tab(.terminal(terminalID: terminalID), layout: layout)

        let surface = try #require(Fixture.surface(Fixture.convert(tab)))

        let expectedContents: [PanelContent?] = [Fixture.file("/a"), Fixture.file("/b"), Fixture.file("/c")]
        let expectedWidth: Double = 0.4
        #expect(surface.side.panels.map(\.content) == expectedContents)
        #expect(surface.side.width == expectedWidth, "only the top-level split sets the width")
        #expect(PanelSurfaceValidator.violations(in: surface).isEmpty)
    }

    // MARK: - Several terminals in one tab

    @Test func multipleTerminalLeavesSkipTheTabNamingTheFirst() {
        let primaryTerminal = UUID()
        let firstExtra = UUID()
        let secondExtra = UUID()
        let layout = Fixture.hsplit([
            .pane(.terminal(terminalID: primaryTerminal)),
            Fixture.vsplit(
                [.pane(.terminal(terminalID: firstExtra)), .pane(.codeViewer(id: UUID(), path: "/v"))],
                [0.5, 0.5]),
            .pane(.terminal(terminalID: secondExtra)),
        ], [0.4, 0.3, 0.3])
        let tab = Fixture.tab(.terminal(terminalID: primaryTerminal), layout: layout)

        let outcome = Fixture.convert(tab)

        #expect(outcome == .skipped("tab \(tab.tabID): terminal \(firstExtra) outside the primary"))
    }

    // MARK: - Notes as panes

    @Test func notePaneBesideAViewerPrimaryIsDropped() throws {
        let noteID = UUID()
        let primary = PaneContent.codeViewer(id: UUID(), path: "/x")
        let webID = UUID()
        let url = try #require(URL(string: "https://example.com/docs"))
        let layout = Fixture.vsplit(
            [.pane(primary), .pane(.note(noteID: noteID)), .pane(.webview(id: webID, url: url))],
            [0.4, 0.3, 0.3])
        let tab = Fixture.tab(primary, layout: layout)
        let ids = IDMinter()

        let surface = try #require(Fixture.surface(Fixture.convert(tab, makeID: { ids.next() })))

        // Only the web pane becomes a panel: a note shows in its worktree
        // panel, never in a tab's own.
        let panelID = try #require(ids.minted.first)
        let expectedPanels = [ViewerPanel(id: panelID, content: .web(url))]
        #expect(ids.minted.count == 1)
        #expect(surface.primary == .file(FileReference(path: "/x")))
        #expect(surface.side.panels == expectedPanels)
        #expect(surface.worktreePanels.isEmpty, "the converter makes no worktree panel")
        #expect(surface.side.width == SideRegion.defaultWidth, "a vertical root sets no width")
    }

    // MARK: - Transcripts

    @Test func transcriptOfThePrimaryTerminalIsAPanel() throws {
        let terminalID = UUID()
        let layout = Fixture.hsplit(
            [.pane(.terminal(terminalID: terminalID)), .pane(.liveTranscript(id: UUID(), terminalID: terminalID))],
            [0.5, 0.5])
        let tab = Fixture.tab(.terminal(terminalID: terminalID), layout: layout)

        let surface = try #require(Fixture.surface(Fixture.convert(tab)))

        let expectedContents: [PanelContent?] = [.transcript(terminalID: terminalID)]
        #expect(surface.side.panels.map(\.content) == expectedContents)
        #expect(PanelSurfaceValidator.violations(in: surface).isEmpty)
    }

    // MARK: - Malformed blobs

    @Test func primaryMissingFromTheTreeKeepsEveryLeafAsAPanel() throws {
        let primary = PaneContent.codeViewer(id: UUID(), path: "/p")
        let layout = Fixture.hsplit(
            [.pane(.codeViewer(id: UUID(), path: "/a")), .pane(.codeViewer(id: UUID(), path: "/b"))],
            [0.7, 0.3])
        let tab = Fixture.tab(primary, layout: layout)

        let surface = try #require(Fixture.surface(Fixture.convert(tab)))

        let expectedContents: [PanelContent?] = [Fixture.file("/a"), Fixture.file("/b")]
        #expect(surface.primary == .file(FileReference(path: "/p")))
        #expect(surface.side.panels.map(\.content) == expectedContents)
        #expect(surface.side.width == SideRegion.defaultWidth, "no child holds the primary")
        #expect(PanelSurfaceValidator.violations(in: surface).isEmpty)
    }

    @Test func malformedRatiosFallBackToTheDefaultWidth() throws {
        let terminalID = UUID()
        let layout = Fixture.hsplit(
            [.pane(.terminal(terminalID: terminalID)), .pane(.codeViewer(id: UUID(), path: "/a"))],
            [CGFloat.nan, 1])
        let tab = Fixture.tab(.terminal(terminalID: terminalID), layout: layout)

        let surface = try #require(Fixture.surface(Fixture.convert(tab)))

        #expect(surface.side.width == SideRegion.defaultWidth)
        #expect(PanelSurfaceValidator.violations(in: surface).isEmpty)
    }
}
