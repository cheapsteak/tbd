import Foundation
import Testing

@testable import TBDApp

@Suite("TranscriptRouting")
struct TranscriptRoutingTests {

    @Test func toggleTranscript_opensWhenNoExistingTranscript() {
        let terminalID = UUID()
        let layout = LayoutNode.pane(.terminal(terminalID: terminalID))

        let result = toggleTranscript(into: layout, terminalID: terminalID, fromPaneID: terminalID)

        guard case .split(let dir, let children, _) = result else {
            Issue.record("Expected split result"); return
        }
        #expect(dir == .horizontal)
        #expect(children.count == 2)
        #expect(children[0] == .pane(.terminal(terminalID: terminalID)))
        guard case .pane(.liveTranscript(_, let tid)) = children[1] else {
            Issue.record("Expected liveTranscript leaf"); return
        }
        #expect(tid == terminalID, "new transcript must carry the same terminalID")
    }

    @Test func toggleTranscript_closesExistingTranscriptForTerminal() {
        let terminalID = UUID()
        let transcriptID = UUID()
        let layout = LayoutNode.split(
            direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: terminalID)),
                .pane(.liveTranscript(id: transcriptID, terminalID: terminalID)),
            ],
            ratios: [0.5, 0.5]
        )

        let result = toggleTranscript(into: layout, terminalID: terminalID, fromPaneID: terminalID)

        // removePane collapses a 2-child split to the surviving child.
        #expect(result == .pane(.terminal(terminalID: terminalID)))
    }

    @Test func toggleTranscript_opensWhenExistingTranscriptIsForDifferentTerminal() {
        let terminalA = UUID()
        let terminalB = UUID()
        let transcriptForB = UUID()
        let layout = LayoutNode.split(
            direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: terminalA)),
                .pane(.liveTranscript(id: transcriptForB, terminalID: terminalB)),
            ],
            ratios: [0.5, 0.5]
        )

        let result = toggleTranscript(into: layout, terminalID: terminalA, fromPaneID: terminalA)

        // B's transcript must survive untouched.
        let transcriptIDs = transcriptTerminalIDs(in: result)
        #expect(transcriptIDs.contains(terminalB), "B's transcript must not be closed")
        #expect(transcriptIDs.contains(terminalA), "a new transcript for A must be added")
        #expect(transcriptIDs.count == 2, "exactly two transcript panes expected")
    }

    /// Collects the `terminalID` carried by every `.liveTranscript` pane in the tree.
    private func transcriptTerminalIDs(in node: LayoutNode) -> [UUID] {
        switch node {
        case .pane(let content):
            if case .liveTranscript(_, let tid) = content { return [tid] }
            return []
        case .split(_, let children, _):
            return children.flatMap { transcriptTerminalIDs(in: $0) }
        }
    }
}
