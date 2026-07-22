import Foundation
import Testing
@testable import TBDShared

@Suite("PanelSurfaceModel")
struct PanelSurfaceModelTests {
    private func sampleSurface() -> WorkspaceTabSurface {
        let panel = PanelSlot(id: UUID(), content: .file(FileReference(path: "docs/plan.md")))
        return WorkspaceTabSurface(
            id: UUID(), worktreeID: UUID(), label: "claude",
            primary: .terminal(terminalID: UUID()),
            layout: .split(SplitNode(
                id: UUID(), direction: .horizontal,
                children: [.primary, .panel(panel)], ratios: [0.65, 0.35])),
            revision: 3
        )
    }

    @Test func surfaceRoundTripsThroughCodable() throws {
        let surface = sampleSurface()
        let decoded = try JSONDecoder().decode(
            WorkspaceTabSurface.self, from: JSONEncoder().encode(surface))
        #expect(decoded == surface)
    }

    @Test func treeAccessorsWalkTheWholeTree() {
        let surface = sampleSurface()
        #expect(surface.layout.primaryCount == 1)
        #expect(surface.layout.allPanelIDs.count == 1)
        #expect(surface.layout.allSplitIDs.count == 1)
        let panelID = surface.layout.allPanelIDs[0]
        #expect(surface.layout.panelSlot(id: panelID)?.content
            == .file(FileReference(path: "docs/plan.md")))
        #expect(surface.layout.panelSlot(id: UUID()) == nil)
    }

    @Test func fileReferenceDefaultsToAutomatic() {
        #expect(FileReference(path: "a.md").presentation == .automatic)
    }

    @Test func panelHistoryIsMRUOverPanelContent() {
        var history = PanelHistory.seeded(with: .file(FileReference(path: "/a")))
        history.recordReplacement(
            outgoing: .file(FileReference(path: "/a")),
            incoming: .web(URL(string: "https://example.com")!))
        #expect(history.entries.count == 2)
        #expect(history.cursor == 0)
    }
}
