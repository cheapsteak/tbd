import Foundation
import Testing
@testable import TBDShared

@Suite("PanelOperationCoding")
struct PanelOperationCodingTests {
    @Test(arguments: [
        PanelOperation.open(
            content: .file(FileReference(path: "a.md", presentation: .rendered)),
            placement: .automatic),
        .open(content: .web(URL(string: "https://example.com/pr/1")!),
              placement: .beside(target: .primary, edge: .right, share: 0.35)),
        .close(panelID: UUID()),
        .move(panelID: UUID(), placement: .beside(target: .panel(UUID()), edge: .below, share: nil)),
        .resize(splitID: UUID(), ratios: [0.25, 0.75]),
        .navigate(panelID: UUID(), destination: .transcript(terminalID: UUID())),
        .history(panelID: UUID(), action: .jump(index: 3)),
        .selectTab(tabID: UUID()),
    ])
    func operationsRoundTrip(op: PanelOperation) throws {
        let envelope = PanelOperationEnvelope(
            operationID: UUID(), worktreeID: UUID(), tabID: UUID(),
            baseRevision: 7, origin: .agentCLI, operation: op)
        let decoded = try JSONDecoder().decode(
            PanelOperationEnvelope.self, from: JSONEncoder().encode(envelope))
        #expect(decoded == envelope)
    }
}
