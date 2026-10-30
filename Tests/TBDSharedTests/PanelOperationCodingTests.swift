import Foundation
import Testing
@testable import TBDShared

@Suite("PanelOperationCoding")
struct PanelOperationCodingTests {
    @Test(arguments: [
        PanelOperation.open(
            content: .file(FileReference(path: "a.md", presentation: .rendered)), newPanel: false),
        .open(content: .web(URL(string: "https://example.com/pr/1")!), newPanel: true),
        .open(content: .note(noteID: UUID()), newPanel: false),
        .open(content: .transcript(terminalID: UUID()), newPanel: false),
        .navigate(panelID: UUID(), destination: .file(FileReference(path: "b.md"))),
        .history(panelID: UUID(), action: .back),
        .history(panelID: UUID(), action: .forward),
        .history(panelID: UUID(), action: .jump(index: 3)),
        .select(panelID: UUID()),
        .close(panelID: UUID()),
        .setCollapsed(true),
        .setCollapsed(false),
        .resize(width: 0.35),
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
