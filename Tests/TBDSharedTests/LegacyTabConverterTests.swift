import CoreGraphics
import Foundation
import Testing
@testable import TBDShared

@Suite("LegacyTabConverter")
struct LegacyTabConverterTests {
    private typealias Fixture = LegacyTabFixture

    /// The side region's width after converting `layout` around `primary`;
    /// nil when the tab is skipped.
    private func width(_ primary: PaneContent, _ layout: LayoutNode) -> Double? {
        Fixture.surface(Fixture.convert(Fixture.tab(primary, layout: layout)))?.side.width
    }

    /// The single panel's history after converting a terminal tab with one
    /// code viewer showing `current`, given that viewer's legacy history.
    private func panelHistory(
        current path: String, legacy: MRUHistory<PaneContent>?, viewerID: UUID = UUID()
    ) -> PanelHistory? {
        let terminalID = UUID()
        let layout = Fixture.hsplit(
            [.pane(.terminal(terminalID: terminalID)), .pane(.codeViewer(id: viewerID, path: path))],
            [0.5, 0.5])
        let tab = Fixture.tab(.terminal(terminalID: terminalID), layout: layout)
        let histories: [UUID: MRUHistory<PaneContent>] = legacy.map { [viewerID: $0] } ?? [:]
        guard let surface = Fixture.surface(Fixture.convert(tab, paneHistories: histories)) else { return nil }
        #expect(PanelSurfaceValidator.violations(in: surface).isEmpty)
        return surface.side.panels.first?.history
    }

    // MARK: - Panels

    @Test func convertsViewerPanesInPreOrder() throws {
        let terminalID = UUID()
        let noteID = UUID()
        let url = try #require(URL(string: "https://example.com/docs"))
        // Pre-order visits /a, the web page, then (past the primary) the note
        // and the primary terminal's transcript.
        let layout = Fixture.hsplit([
            Fixture.vsplit(
                [.pane(.codeViewer(id: UUID(), path: "/a")), .pane(.webview(id: UUID(), url: url))],
                [0.5, 0.5]),
            Fixture.vsplit([
                .pane(.terminal(terminalID: terminalID)),
                Fixture.hsplit(
                    [.pane(.note(noteID: noteID)), .pane(.liveTranscript(id: UUID(), terminalID: terminalID))],
                    [0.5, 0.5]),
            ], [0.5, 0.5]),
        ], [0.5, 0.5])
        let tab = Fixture.tab(.terminal(terminalID: terminalID), layout: layout, label: "claude")
        let ids = IDMinter()

        let outcome = Fixture.convert(tab, makeID: { ids.next() })

        try #require(ids.minted.count == 4)
        let panels = [
            ViewerPanel(id: ids.minted[0], content: Fixture.file("/a")),
            ViewerPanel(id: ids.minted[1], content: .web(url)),
            ViewerPanel(id: ids.minted[2], content: .note(noteID: noteID)),
            ViewerPanel(id: ids.minted[3], content: .transcript(terminalID: terminalID)),
        ]
        let expected = WorkspaceTabSurface(
            id: tab.tabID, worktreeID: Fixture.worktreeID, label: "claude",
            primary: .terminal(terminalID: terminalID),
            side: SideRegion(
                panels: panels, activePanelID: ids.minted[0], recency: ids.minted,
                collapsed: false, width: SideRegion.defaultWidth),
            revision: 0)
        #expect(outcome == .converted(expected))
    }

    @Test func mintsFreshPanelIDs() throws {
        let terminalID = UUID()
        let noteID = UUID()
        let viewerID = UUID()
        let webID = UUID()
        let transcriptID = UUID()
        let url = try #require(URL(string: "https://example.com"))
        let layout = Fixture.hsplit([
            .pane(.terminal(terminalID: terminalID)),
            Fixture.vsplit([
                .pane(.note(noteID: noteID)),
                .pane(.codeViewer(id: viewerID, path: "/a")),
                .pane(.webview(id: webID, url: url)),
                .pane(.liveTranscript(id: transcriptID, terminalID: terminalID)),
            ], [0.25, 0.25, 0.25, 0.25]),
        ], [0.5, 0.5])
        let tab = Fixture.tab(.terminal(terminalID: terminalID), layout: layout)
        let ids = IDMinter()

        let surface = try #require(Fixture.surface(Fixture.convert(tab, makeID: { ids.next() })))

        let panelIDs = surface.side.panels.map(\.id)
        let legacyIDs: Set<UUID> = [tab.tabID, terminalID, noteID, viewerID, webID, transcriptID]
        #expect(panelIDs == ids.minted, "every panel ID comes from makeID")
        #expect(Set(panelIDs).count == 4)
        #expect(Set(panelIDs).isDisjoint(with: legacyIDs), "no legacy pane ID is reused, the note's included")

        // One note open in two tabs: the second tab's panel gets its own ID.
        let otherTerminal = UUID()
        let otherTab = Fixture.tab(
            .terminal(terminalID: otherTerminal),
            layout: Fixture.hsplit(
                [.pane(.terminal(terminalID: otherTerminal)), .pane(.note(noteID: noteID))], [0.5, 0.5]))
        let otherSurface = try #require(Fixture.surface(Fixture.convert(otherTab)))
        let otherIDs = Set(otherSurface.side.panels.map(\.id))
        #expect(otherIDs.count == 1)
        #expect(otherIDs.isDisjoint(with: Set(panelIDs)))
    }

    @Test func primaryOnlyTabHasEmptyRegion() throws {
        let terminalID = UUID()
        let terminalTab = Fixture.tab(.terminal(terminalID: terminalID), label: "shell")
        let expectedTerminal = WorkspaceTabSurface(
            id: terminalTab.tabID, worktreeID: Fixture.worktreeID, label: "shell",
            primary: .terminal(terminalID: terminalID), side: .empty, revision: 0)
        #expect(Fixture.convert(terminalTab) == .converted(expectedTerminal))

        // An explicit single-pane layout reads the same as no layout.
        let noteID = UUID()
        let noteTab = Fixture.tab(.note(noteID: noteID), layout: .pane(.note(noteID: noteID)))
        let expectedNote = WorkspaceTabSurface(
            id: noteTab.tabID, worktreeID: Fixture.worktreeID, label: nil,
            primary: .note(noteID: noteID), side: .empty, revision: 0)
        #expect(Fixture.convert(noteTab) == .converted(expectedNote))
    }

    @Test func skipsTabWithTerminalOutsidePrimary() {
        let primaryTerminal = UUID()
        let otherTerminal = UUID()
        let layout = Fixture.hsplit([
            .pane(.terminal(terminalID: primaryTerminal)),
            Fixture.vsplit(
                [.pane(.codeViewer(id: UUID(), path: "/a")), .pane(.terminal(terminalID: otherTerminal))],
                [0.5, 0.5]),
        ], [0.5, 0.5])
        let tab = Fixture.tab(.terminal(terminalID: primaryTerminal), layout: layout)

        #expect(Fixture.convert(tab) == .skipped("tab \(tab.tabID): terminal \(otherTerminal) outside the primary"))

        // A terminal beside a viewer primary is outside the primary too.
        let viewer = PaneContent.codeViewer(id: UUID(), path: "/v")
        let viewerTab = Fixture.tab(
            viewer,
            layout: Fixture.hsplit([.pane(viewer), .pane(.terminal(terminalID: primaryTerminal))], [0.5, 0.5]))

        #expect(Fixture.convert(viewerTab)
                == .skipped("tab \(viewerTab.tabID): terminal \(primaryTerminal) outside the primary"))
    }

    /// The test `convert` skips by, which the app also asks to render a tab
    /// legacy before any sync has named it skipped.
    @Test func terminalOutsidePrimaryNamesTheTerminalBesideThePrimary() {
        let primaryTerminal = UUID()
        let otherTerminal = UUID()
        let primary = PaneContent.terminal(terminalID: primaryTerminal)
        let terminalSplit = Fixture.hsplit(
            [.pane(primary), .pane(.terminal(terminalID: otherTerminal))], [0.5, 0.5])
        let viewerSplit = Fixture.hsplit(
            [.pane(primary), .pane(.codeViewer(id: UUID(), path: "/a"))], [0.5, 0.5])

        #expect(LegacyTabConverter.terminalOutsidePrimary(content: primary, layout: terminalSplit) == otherTerminal)
        // Only viewers beside the primary, the primary alone, or no layout.
        #expect(LegacyTabConverter.terminalOutsidePrimary(content: primary, layout: viewerSplit) == nil)
        #expect(LegacyTabConverter.terminalOutsidePrimary(content: primary, layout: .pane(primary)) == nil)
        #expect(LegacyTabConverter.terminalOutsidePrimary(content: primary, layout: nil) == nil)
    }

    @Test func skipsATabTheModelCannotExpress() {
        // Two legacy panes on one terminal's transcript: the model allows one
        // view per terminal, so the tab stays legacy rather than lose a pane.
        let terminalID = UUID()
        let layout = Fixture.hsplit([
            .pane(.terminal(terminalID: terminalID)),
            .pane(.liveTranscript(id: UUID(), terminalID: terminalID)),
            .pane(.liveTranscript(id: UUID(), terminalID: terminalID)),
        ], [0.4, 0.3, 0.3])
        let tab = Fixture.tab(.terminal(terminalID: terminalID), layout: layout)

        guard case .skipped(let reason) = Fixture.convert(tab) else {
            Issue.record("expected the tab to be skipped")
            return
        }
        #expect(reason.hasPrefix("tab \(tab.tabID): "))
        #expect(reason.contains("duplicateTranscriptView"))
    }

    // MARK: - Histories

    @Test func filtersHistoryToCurrentKind() throws {
        let viewerID = UUID()
        let url = try #require(URL(string: "https://example.com"))
        let legacy = MRUHistory<PaneContent>(
            entries: [
                .webview(id: viewerID, url: url),
                .codeViewer(id: viewerID, path: "/b"),
                .liveTranscript(id: viewerID, terminalID: UUID()),
                .terminal(terminalID: UUID()),
                .codeViewer(id: viewerID, path: "/a"),
                .note(noteID: UUID()),
                .codeViewer(id: viewerID, path: "/c"),
            ],
            cursor: 4)

        let history = try #require(panelHistory(current: "/a", legacy: legacy, viewerID: viewerID))

        let expectedEntries = [Fixture.file("/b"), Fixture.file("/a"), Fixture.file("/c")]
        #expect(history.entries == expectedEntries)
        #expect(history.cursor == 1)
    }

    @Test func cursorFollowsThePanesCurrentContent() throws {
        // The pane is authoritative for what it shows, wherever the legacy
        // cursor points — even out of range.
        let viewerID = UUID()
        for legacyCursor in [0, 7] {
            let legacy = MRUHistory<PaneContent>(
                entries: [.codeViewer(id: viewerID, path: "/b"), .codeViewer(id: viewerID, path: "/a")],
                cursor: legacyCursor)

            let history = try #require(panelHistory(current: "/a", legacy: legacy, viewerID: viewerID))

            let expectedEntries = [Fixture.file("/b"), Fixture.file("/a")]
            #expect(history.entries == expectedEntries)
            #expect(history.cursor == 1)
        }
    }

    @Test func seedsHistoryWhenAbsent() throws {
        let viewerID = UUID()
        let url = try #require(URL(string: "https://example.com"))
        let seeded = PanelHistory.seeded(with: Fixture.file("/a"))
        let withoutCurrent = MRUHistory<PaneContent>(
            entries: [.codeViewer(id: viewerID, path: "/b"), .codeViewer(id: viewerID, path: "/c")],
            cursor: 0)
        let otherKindsOnly = MRUHistory<PaneContent>(
            entries: [.webview(id: viewerID, url: url), .liveTranscript(id: viewerID, terminalID: UUID())],
            cursor: 0)

        #expect(panelHistory(current: "/a", legacy: nil, viewerID: viewerID) == seeded)
        #expect(panelHistory(current: "/a", legacy: MRUHistory<PaneContent>(), viewerID: viewerID) == seeded)
        #expect(panelHistory(current: "/a", legacy: withoutCurrent, viewerID: viewerID) == seeded)
        #expect(panelHistory(current: "/a", legacy: otherKindsOnly, viewerID: viewerID) == seeded)
    }

    @Test func dedupesEntriesThatMapToTheSameContent() throws {
        // A legacy code viewer carries its pane ID, so two entries for one
        // path with different pane IDs differ as `PaneContent` and are one
        // `PanelContent`. The first in MRU order is kept.
        let viewerID = UUID()
        let legacy = MRUHistory<PaneContent>(
            entries: [
                .codeViewer(id: UUID(), path: "/b"),
                .codeViewer(id: viewerID, path: "/a"),
                .codeViewer(id: UUID(), path: "/b"),
                .codeViewer(id: UUID(), path: "/a"),
                .codeViewer(id: UUID(), path: "/c"),
            ],
            cursor: 3)

        let history = try #require(panelHistory(current: "/a", legacy: legacy, viewerID: viewerID))

        let expectedEntries = [Fixture.file("/b"), Fixture.file("/a"), Fixture.file("/c")]
        #expect(history.entries == expectedEntries)
        #expect(history.cursor == 1)
    }

    @Test func capsHistoryKeepingTheCurrentEntry() throws {
        let viewerID = UUID()
        let paths = (0..<12).map { "/f\($0)" }
        let entries = paths.map { PaneContent.codeViewer(id: viewerID, path: $0) }
        let cap = PanelHistory.maxEntries

        // The current entry is the oldest: it survives in the last slot.
        let oldestCurrent = try #require(panelHistory(
            current: "/f11", legacy: MRUHistory<PaneContent>(entries: entries, cursor: 11), viewerID: viewerID))
        let lastSlot = cap - 1
        let keptPaths: [String] = Array(paths.prefix(lastSlot)) + ["/f11"]
        let expectedOldest = keptPaths.map { Fixture.file($0) }
        #expect(oldestCurrent.entries == expectedOldest)
        #expect(oldestCurrent.cursor == lastSlot)

        // The current entry is recent: the tail is evicted.
        let recentCurrent = try #require(panelHistory(
            current: "/f2", legacy: MRUHistory<PaneContent>(entries: entries, cursor: 2), viewerID: viewerID))
        let expectedRecent: [PanelContent] = paths.prefix(cap).map { Fixture.file($0) }
        #expect(recentCurrent.entries == expectedRecent)
        #expect(recentCurrent.cursor == 2)
    }

    // MARK: - Width

    @Test func widthFromTopLevelRatio() {
        let primary = PaneContent.terminal(terminalID: UUID())
        let viewer = LayoutNode.pane(.codeViewer(id: UUID(), path: "/a"))
        let web = LayoutNode.pane(.webview(id: UUID(), url: URL(fileURLWithPath: "/tmp/page.html")))
        let primaryLeft = Fixture.hsplit([.pane(primary), viewer], [0.6, 0.4])
        let primaryRight = Fixture.hsplit([viewer, .pane(primary)], [0.4, 0.6])
        let primaryNested = Fixture.hsplit(
            [Fixture.vsplit([.pane(primary), viewer], [0.5, 0.5]), web], [0.6, 0.4])
        let expected: Double = 0.4

        #expect(width(primary, primaryLeft) == expected)
        #expect(width(primary, primaryRight) == expected)
        #expect(width(primary, primaryNested) == expected, "the child holding the primary sets the share")
    }

    @Test func widthClampedAndDefaulted() {
        let primary = PaneContent.terminal(terminalID: UUID())
        let viewer = LayoutNode.pane(.codeViewer(id: UUID(), path: "/a"))
        let other = LayoutNode.pane(.codeViewer(id: UUID(), path: "/b"))
        let narrowSide = Fixture.hsplit([.pane(primary), viewer], [0.95, 0.05])
        let wideSide = Fixture.hsplit([.pane(primary), viewer], [0.05, 0.95])
        let vertical = Fixture.vsplit([.pane(primary), viewer], [0.6, 0.4])
        let threeColumns = Fixture.hsplit([.pane(primary), viewer, other], [0.4, 0.3, 0.3])
        let nanRatio = Fixture.hsplit([.pane(primary), viewer], [CGFloat.nan, 0.5])
        let infiniteRatio = Fixture.hsplit([.pane(primary), viewer], [CGFloat.infinity, 0.5])
        let missingRatio = Fixture.hsplit([.pane(primary), viewer], [1])
        let noPrimaryChild = Fixture.hsplit([viewer, other], [0.7, 0.3])

        #expect(width(primary, narrowSide) == SideRegion.widthRange.lowerBound)
        #expect(width(primary, wideSide) == SideRegion.widthRange.upperBound)
        #expect(width(primary, vertical) == SideRegion.defaultWidth)
        #expect(width(primary, threeColumns) == SideRegion.defaultWidth)
        #expect(width(primary, nanRatio) == SideRegion.defaultWidth)
        #expect(width(primary, infiniteRatio) == SideRegion.defaultWidth)
        #expect(width(primary, missingRatio) == SideRegion.defaultWidth)
        #expect(width(primary, noPrimaryChild) == SideRegion.defaultWidth)
    }

    // MARK: - Validity

    @Test func everyConvertedSurfacePassesTheValidator() throws {
        let terminalID = UUID()
        let viewerID = UUID()
        let noteID = UUID()
        let url = try #require(URL(string: "https://example.com"))
        let viewer = PaneContent.codeViewer(id: viewerID, path: "/a")
        let mixedHistory = MRUHistory<PaneContent>(
            entries: [
                .codeViewer(id: UUID(), path: "/a"), .webview(id: viewerID, url: url),
                viewer, .terminal(terminalID: UUID()),
            ],
            cursor: 2)
        let tabs: [LegacyTabPayload] = [
            Fixture.tab(.terminal(terminalID: terminalID)),
            Fixture.tab(.note(noteID: noteID)),
            Fixture.tab(.webview(id: UUID(), url: url)),
            Fixture.tab(.liveTranscript(id: UUID(), terminalID: terminalID)),
            Fixture.tab(
                .terminal(terminalID: terminalID),
                layout: Fixture.hsplit([.pane(.terminal(terminalID: terminalID)), .pane(viewer)], [0.6, 0.4])),
            Fixture.tab(
                viewer,
                layout: Fixture.vsplit([
                    .pane(viewer), .pane(.note(noteID: noteID)),
                    .pane(.liveTranscript(id: UUID(), terminalID: terminalID)),
                ], [0.4, 0.3, 0.3])),
            Fixture.tab(
                .terminal(terminalID: terminalID),
                layout: Fixture.hsplit([.pane(.terminal(terminalID: terminalID)), .pane(viewer)], [0.99, 0.01])),
        ]

        for tab in tabs {
            let outcome = Fixture.convert(tab, paneHistories: [viewerID: mixedHistory])
            let surface = try #require(Fixture.surface(outcome), "tab \(tab.tabID) was skipped: \(outcome)")
            #expect(PanelSurfaceValidator.violations(in: surface).isEmpty)
        }
    }

    // MARK: - Content mapping

    @Test func panelContentMapsViewersAndRejectsTerminal() throws {
        let url = try #require(URL(string: "https://example.com"))
        let noteID = UUID()
        let terminalID = UUID()
        #expect(LegacyTabConverter.panelContent(from: .terminal(terminalID: UUID())) == nil)
        #expect(LegacyTabConverter.panelContent(from: .codeViewer(id: UUID(), path: "/a")) == Fixture.file("/a"))
        #expect(LegacyTabConverter.panelContent(from: .webview(id: UUID(), url: url)) == .web(url))
        #expect(LegacyTabConverter.panelContent(from: .note(noteID: noteID)) == .note(noteID: noteID))
        #expect(LegacyTabConverter.panelContent(from: .liveTranscript(id: UUID(), terminalID: terminalID))
                == .transcript(terminalID: terminalID))
    }

    @Test func primaryContentMapsEveryVariant() throws {
        let url = try #require(URL(string: "https://example.com"))
        let noteID = UUID()
        let terminalID = UUID()
        #expect(LegacyTabConverter.primaryContent(from: .terminal(terminalID: terminalID))
                == .terminal(terminalID: terminalID))
        #expect(LegacyTabConverter.primaryContent(from: .codeViewer(id: UUID(), path: "/a"))
                == .file(FileReference(path: "/a")))
        #expect(LegacyTabConverter.primaryContent(from: .webview(id: UUID(), url: url)) == .web(url))
        #expect(LegacyTabConverter.primaryContent(from: .note(noteID: noteID)) == .note(noteID: noteID))
        #expect(LegacyTabConverter.primaryContent(from: .liveTranscript(id: UUID(), terminalID: terminalID))
                == .transcript(terminalID: terminalID))
    }
}
