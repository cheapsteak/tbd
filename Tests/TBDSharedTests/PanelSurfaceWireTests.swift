import Testing
import Foundation
@testable import TBDShared

@Suite("PanelSurfaceWireTests")
struct PanelSurfaceWireTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    /// A surface with a side region whose panel carries a multi-entry history,
    /// so a round trip covers histories as well as the region.
    private func sampleSurface() -> WorkspaceTabSurface {
        let panelID = UUID()
        var navigated = PanelHistory.seeded(with: .file(FileReference(path: "docs/b.md")))
        navigated.recordReplacement(
            outgoing: .file(FileReference(path: "docs/b.md")),
            incoming: .file(FileReference(path: "docs/a.md", presentation: .rendered)))
        return WorkspaceTabSurface(
            id: UUID(), worktreeID: UUID(), label: "claude",
            primary: .terminal(terminalID: UUID()),
            side: SideRegion(
                panels: [ViewerPanel(id: panelID, history: navigated)],
                activePanelID: panelID, recency: [panelID], collapsed: true, width: 0.35),
            revision: 7)
    }

    /// `sampleSurface()` with a note panel in front and a Changes panel,
    /// both worktree panels.
    private func sampleSurfaceWithWorktreePanels() -> WorkspaceTabSurface {
        var surface = sampleSurface()
        let note = WorktreePanel(id: UUID(), content: .note(noteID: UUID()))
        let changes = WorktreePanel(id: UUID(), content: .changes)
        surface.worktreePanels = [note, changes]
        surface.side.activePanelID = note.id
        return surface
    }

    /// `value` encoded, then with `key` removed from the top-level object and
    /// from each object in `nestedIn`'s array: the JSON a build that predates
    /// the field writes. Records an issue when `key` was not there to remove.
    private func encodedWithout<T: Encodable>(
        _ key: String, from value: T, nestedIn arrayKey: String? = nil
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        let json = try JSONSerialization.jsonObject(with: encoded)
        var object = try #require(json as? [String: Any])
        let hadKey = object.removeValue(forKey: key) != nil
        #expect(hadKey, "precondition: \(key) was encoded")
        if let arrayKey {
            let nested = try #require(object[arrayKey] as? [[String: Any]])
            object[arrayKey] = nested.map { element -> [String: Any] in
                var stripped = element
                stripped.removeValue(forKey: key)
                return stripped
            }
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func panelGetRoundTrips() throws {
        let result = PanelGetResult(tabs: [sampleSurface()], activeTabID: UUID())
        #expect(try roundTrip(result) == result)
        let params = PanelGetParams(worktreeID: UUID(), tabID: nil)
        #expect(try roundTrip(params) == params)
    }

    @Test func roundTripKeepsWorktreePanelsAndChanges() throws {
        let surface = sampleSurfaceWithWorktreePanels()
        #expect(PanelSurfaceValidator.violations(in: surface).isEmpty, "precondition: a valid surface")
        let decoded = try roundTrip(surface)
        #expect(decoded == surface)
        let decodedContents: [WorktreePanelContent] = decoded.worktreePanels.map(\.content)
        #expect(decodedContents.contains(.changes))

        let result = PanelGetResult(
            tabs: [surface], activeTabID: surface.id, worktreePanels: surface.worktreePanels)
        let decodedResult = try roundTrip(result)
        #expect(decodedResult == result)
        #expect(decodedResult.worktreePanels == surface.worktreePanels)

        let open = PanelOperation.open(content: .changes, newPanel: false)
        #expect(try roundTrip(open) == open)
    }

    /// An app or CLI built before worktree panels talks to this daemon, or the
    /// reverse: a surface without the key decodes, with no worktree panels.
    @Test func surfaceWithoutWorktreePanelsKeyDecodes() throws {
        let surface = sampleSurfaceWithWorktreePanels()
        let data = try encodedWithout("worktreePanels", from: surface)

        let decoded = try JSONDecoder().decode(WorkspaceTabSurface.self, from: data)

        var expected = surface
        expected.worktreePanels = []
        #expect(decoded == expected)
    }

    @Test func getResultWithoutWorktreePanelsKeyDecodes() throws {
        let surface = sampleSurfaceWithWorktreePanels()
        let result = PanelGetResult(
            tabs: [surface], activeTabID: surface.id, worktreePanels: surface.worktreePanels)
        let data = try encodedWithout("worktreePanels", from: result, nestedIn: "tabs")

        let decoded = try JSONDecoder().decode(PanelGetResult.self, from: data)

        var expectedTab = surface
        expectedTab.worktreePanels = []
        #expect(decoded == PanelGetResult(tabs: [expectedTab], activeTabID: surface.id))
        #expect(decoded.worktreePanels.isEmpty)
    }

    @Test func panelApplyRoundTrips() throws {
        let envelope = PanelOperationEnvelope(
            operationID: UUID(), worktreeID: UUID(), tabID: UUID(),
            baseRevision: 3, origin: .agentCLI,
            operation: .open(content: .file(FileReference(path: "docs/a.md")), newPanel: false))
        #expect(try roundTrip(PanelApplyParams(envelope: envelope)) == PanelApplyParams(envelope: envelope))
        let result = PanelApplyResult(tab: sampleSurface(), replayed: true)
        #expect(try roundTrip(result) == result)
    }

    @Test func syncTabsParamsRoundTripWithLegacyTypes() throws {
        let terminalID = UUID()
        let slotID = UUID()
        let params = PanelSyncTabsParams(
            worktreeID: UUID(),
            tabs: [
                LegacyTabPayload(
                    tabID: UUID(), label: "claude",
                    content: .terminal(terminalID: terminalID),
                    layout: .split(id: UUID(), direction: .horizontal,
                                   children: [.pane(.terminal(terminalID: terminalID)),
                                              .pane(.codeViewer(id: slotID, path: "a.md"))],
                                   ratios: [0.6, 0.4])),
                LegacyTabPayload(tabID: UUID(), label: nil, content: .note(noteID: UUID()), layout: nil),
            ],
            paneHistories: [slotID: .seeded(with: .codeViewer(id: slotID, path: "a.md"))])
        #expect(try roundTrip(params) == params)
    }

    @Test func syncTabsResultRoundTrips() throws {
        let skippedID = UUID()
        let result = PanelSyncTabsResult(
            importedTabIDs: [UUID(), UUID()], reparentedTabIDs: [UUID()], removedTabIDs: [UUID()],
            skippedTabIDs: [skippedID],
            skipped: ["tab \(skippedID.uuidString): terminal outside the primary"])
        let decoded = try roundTrip(result)
        #expect(decoded == result)
        #expect(decoded.skippedTabIDs == [skippedID])
        let empty = PanelSyncTabsResult(
            importedTabIDs: [], reparentedTabIDs: [], removedTabIDs: [], skippedTabIDs: [], skipped: [])
        #expect(try roundTrip(empty) == empty)
    }

    @Test func panelSurfaceDeltaRoundTripsThroughStateDelta() throws {
        let delta = StateDelta.panelSurfaceChanged(PanelSurfaceDelta(
            worktreeID: UUID(), tabs: [sampleSurface()], removedTabIDs: [UUID()],
            activeTabID: nil, originOperationID: UUID()))
        let decoded = try JSONDecoder().decode(StateDelta.self, from: JSONEncoder().encode(delta))
        guard case .panelSurfaceChanged(let payload) = decoded,
              case .panelSurfaceChanged(let original) = delta else {
            Issue.record("wrong case"); return
        }
        #expect(payload == original)
    }

    @Test func rpcMethodConstants() {
        #expect(RPCMethod.panelGet == "panel.get")
        #expect(RPCMethod.panelApply == "panel.apply")
        #expect(RPCMethod.panelSyncTabs == "panel.syncTabs")
    }
}
