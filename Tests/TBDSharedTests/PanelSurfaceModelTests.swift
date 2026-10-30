import Foundation
import Testing
@testable import TBDShared

@Suite("PanelSurfaceModel")
struct PanelSurfaceModelTests {
    private static let site = URL(string: "https://example.com/docs")!
    private let plan = PanelContent.file(FileReference(path: "docs/plan.md", presentation: .rendered))
    private let old = PanelContent.file(FileReference(path: "/old.md"))

    /// A surface exercising every field: all four panel kinds, a file panel
    /// whose cursor is not at the front, a recency order unlike the strip
    /// order, a collapsed region and a non-default width.
    private func fullSurface() -> WorkspaceTabSurface {
        var fileHistory = PanelHistory.seeded(with: old)
        fileHistory.recordReplacement(outgoing: old, incoming: plan)
        _ = fileHistory.goBack()
        let filePanel = ViewerPanel(id: UUID(), history: fileHistory)
        let webPanel = ViewerPanel(id: UUID(), content: .web(Self.site))
        let notePanel = ViewerPanel(id: UUID(), content: .note(noteID: UUID()))
        let transcriptPanel = ViewerPanel(id: UUID(), content: .transcript(terminalID: UUID()))
        return WorkspaceTabSurface(
            id: UUID(), worktreeID: UUID(), label: "claude",
            primary: .terminal(terminalID: UUID()),
            side: SideRegion(
                panels: [filePanel, webPanel, notePanel, transcriptPanel],
                activePanelID: webPanel.id,
                recency: [webPanel.id, transcriptPanel.id, filePanel.id, notePanel.id],
                collapsed: true, width: 0.35),
            revision: 7)
    }

    // MARK: - Surface

    @Test func surfaceRoundTripsThroughCodable() throws {
        let surface = fullSurface()
        #expect(PanelSurfaceValidator.violations(in: surface) == [], "fixture is a valid surface")
        let decoded = try JSONDecoder().decode(
            WorkspaceTabSurface.self, from: JSONEncoder().encode(surface))
        #expect(decoded == surface)
        let filePanelID = try #require(surface.side.panels.first?.id)
        #expect(decoded.side.panel(id: filePanelID)?.content == old,
                "the decoded cursor still points at the entry it pointed at")
    }

    @Test func surfaceDefaultsToAnEmptySideRegion() {
        let surface = WorkspaceTabSurface(
            id: UUID(), worktreeID: UUID(), primary: .terminal(terminalID: UUID()))
        #expect(surface.side == .empty)
        #expect(surface.label == nil)
        #expect(surface.revision == 0)
    }

    // MARK: - Kinds

    @Test func panelContentKindCoversEveryCase() {
        #expect(PanelContent.file(FileReference(path: "/a")).kind == .file)
        #expect(PanelContent.web(Self.site).kind == .web)
        #expect(PanelContent.note(noteID: UUID()).kind == .note)
        #expect(PanelContent.transcript(terminalID: UUID()).kind == .transcript)
    }

    // MARK: - Viewer panel

    @Test func viewerPanelContentIsTheCursorEntry() {
        let seeded = ViewerPanel(id: UUID(), content: plan)
        #expect(seeded.history.entries == [plan])
        #expect(seeded.content == plan)

        var history = PanelHistory.seeded(with: old)
        history.recordReplacement(outgoing: old, incoming: plan)
        var panel = ViewerPanel(id: UUID(), history: history)
        #expect(panel.content == plan)

        _ = panel.history.goBack()
        #expect(panel.history.cursor == 1)
        #expect(panel.content == old, "content follows the cursor, with no copy to update")
    }

    @Test func viewerPanelContentIsNilWhenHistoryIsMalformed() {
        let outOfRange = ViewerPanel(id: UUID(), history: PanelHistory(entries: [plan], cursor: 4))
        #expect(outOfRange.content == nil)
        let empty = ViewerPanel(id: UUID(), history: PanelHistory())
        #expect(empty.content == nil)
    }

    /// The spec stores no `content` field: content is derived from history.
    @Test func viewerPanelEncodesNoContentField() throws {
        let data = try JSONEncoder().encode(ViewerPanel(id: UUID(), content: plan))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = (object ?? [:]).keys.sorted()
        #expect(keys == ["history", "id"])
    }

    // MARK: - Side region

    @Test func emptyRegionIsHiddenAtTheDefaultWidth() {
        let empty = SideRegion.empty
        #expect(empty.panels.isEmpty)
        #expect(empty.activePanelID == nil)
        #expect(empty.recency.isEmpty)
        #expect(!empty.collapsed)
        #expect(empty.width == SideRegion.defaultWidth)
        #expect(!empty.isVisible)
    }

    @Test func regionIsVisibleOnlyWithPanelsAndNotCollapsed() {
        let panel = ViewerPanel(id: UUID(), content: plan)
        var side = SideRegion(panels: [panel], activePanelID: panel.id, recency: [panel.id])
        #expect(side.isVisible)

        side.collapsed = true
        #expect(!side.isVisible)
        #expect(side.panels == [panel], "collapsing keeps the panels")

        let expandedButEmpty = SideRegion(panels: [], activePanelID: nil, recency: [], collapsed: false)
        #expect(!expandedButEmpty.isVisible, "no panels means hidden even when not collapsed")
    }

    @Test func panelLooksUpByID() {
        let a = ViewerPanel(id: UUID(), content: plan)
        let b = ViewerPanel(id: UUID(), content: .web(Self.site))
        let side = SideRegion(panels: [a, b], activePanelID: a.id, recency: [a.id, b.id])
        #expect(side.panel(id: b.id) == b)
        #expect(side.panel(id: a.id) == a)
        #expect(side.panel(id: UUID()) == nil)
    }

    @Test func widthRangeAndDefaultMatchTheLegacyDivider() {
        let expectedRange: ClosedRange<Double> = 0.1...0.9
        let expectedDefault: Double = 0.5
        #expect(SideRegion.widthRange == expectedRange)
        #expect(SideRegion.defaultWidth == expectedDefault)
    }

    // MARK: - Content references and history

    @Test func fileReferenceDefaultsToAutomatic() {
        #expect(FileReference(path: "a.md").presentation == .automatic)
    }

    @Test func panelHistoryIsMRUOverPanelContent() {
        var history = PanelHistory.seeded(with: .file(FileReference(path: "/a")))
        history.recordReplacement(
            outgoing: .file(FileReference(path: "/a")),
            incoming: .web(Self.site))
        #expect(history.entries.count == 2)
        #expect(history.cursor == 0)
    }
}
