import Testing
import Foundation
@testable import TBDShared

@Suite("PanelSurfaceWireTests")
struct PanelSurfaceWireTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test func panelGetRoundTrips() throws {
        let result = PanelGetResult(
            tabs: [WorkspaceTabSurface(id: UUID(), worktreeID: UUID(),
                                       primary: .terminal(terminalID: UUID()), layout: .primary)],
            activeTabID: UUID())
        #expect(try roundTrip(result) == result)
        let params = PanelGetParams(worktreeID: UUID(), tabID: nil)
        #expect(try roundTrip(params) == params)
    }

    @Test func panelApplyRoundTrips() throws {
        let envelope = PanelOperationEnvelope(
            operationID: UUID(), worktreeID: UUID(), tabID: UUID(),
            baseRevision: 3, origin: .agentCLI,
            operation: .open(content: .file(FileReference(path: "docs/a.md")), placement: .automatic))
        #expect(try roundTrip(PanelApplyParams(envelope: envelope)) == PanelApplyParams(envelope: envelope))
    }

    @Test func importParamsRoundTripWithLegacyTypes() throws {
        let slotID = UUID()
        let params = PanelImportParams(
            worktreeID: UUID(),
            tabs: [LegacyTabPayload(
                tabID: UUID(), label: "claude",
                content: .terminal(terminalID: UUID()),
                layout: .split(id: UUID(), direction: .horizontal,
                               children: [.pane(.terminal(terminalID: UUID())),
                                          .pane(.codeViewer(id: slotID, path: "a.md"))],
                               ratios: [0.6, 0.4]))],
            tabOrder: [], activeTabID: nil,
            paneHistories: [slotID: .seeded(with: .codeViewer(id: slotID, path: "a.md"))])
        #expect(try roundTrip(params) == params)
    }

    @Test func panelSurfaceDeltaRoundTripsThroughStateDelta() throws {
        let delta = StateDelta.panelSurfaceChanged(PanelSurfaceDelta(
            worktreeID: UUID(), tabs: [], removedTabIDs: [UUID()],
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
        #expect(RPCMethod.panelImportLegacy == "panel.importLegacy")
    }
}
