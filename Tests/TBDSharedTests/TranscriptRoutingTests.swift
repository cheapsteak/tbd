import Foundation
import Testing

@testable import TBDShared

@Suite("TranscriptRouting")
struct TranscriptRoutingTests {

    @Test func toggleTranscript_opensWhenNoExistingTranscript() {
        let terminalID = UUID()
        let layout = LayoutNode.pane(.terminal(terminalID: terminalID))

        let result = toggleTranscript(into: layout, terminalID: terminalID, fromPaneID: terminalID)

        #expect(result.replaced == nil)
        #expect(result.removedPaneID == nil)
        guard case .split(let dir, let children, _) = result.layout else {
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
        #expect(result.layout == .pane(.terminal(terminalID: terminalID)))
        #expect(result.removedPaneID == transcriptID, "call site prunes this pane's history")
        #expect(result.replaced == nil)
    }

    @Test func toggleTranscript_reusesViewerSlotForDifferentTerminalsTranscript() {
        let terminalA = UUID()
        let terminalB = UUID()
        let slotID = UUID()
        let outgoing = PaneContent.liveTranscript(id: slotID, terminalID: terminalB)
        let layout = LayoutNode.split(
            direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: terminalA)),
                .pane(outgoing),
            ],
            ratios: [0.5, 0.5]
        )

        let result = toggleTranscript(into: layout, terminalID: terminalA, fromPaneID: terminalA)

        // B's transcript is a viewer-class slot: A's transcript replaces it in
        // place, keeping the slot UUID.
        guard case .split(_, let children, _) = result.layout,
              case .pane(.liveTranscript(let id, let tid)) = children[1]
        else {
            Issue.record("Expected transcript slot in right child"); return
        }
        #expect(id == slotID, "slot UUID must be preserved")
        #expect(tid == terminalA)
        #expect(result.replaced == .init(
            paneID: slotID,
            outgoing: outgoing,
            incoming: .liveTranscript(id: slotID, terminalID: terminalA)
        ))
    }

    @Test func toggleTranscript_reusesCodeViewerSlot() {
        let terminalID = UUID()
        let slotID = UUID()
        let outgoing = PaneContent.codeViewer(id: slotID, path: "/a.md")
        let layout = LayoutNode.split(
            direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: terminalID)),
                .pane(outgoing),
            ],
            ratios: [0.5, 0.5]
        )

        let result = toggleTranscript(into: layout, terminalID: terminalID, fromPaneID: terminalID)

        guard case .split(_, let children, _) = result.layout,
              case .pane(.liveTranscript(let id, let tid)) = children[1]
        else {
            Issue.record("Expected codeViewer slot replaced by transcript"); return
        }
        #expect(id == slotID)
        #expect(tid == terminalID)
        #expect(result.replaced?.outgoing == outgoing)
    }

    @Test func toggleTranscript_splitsWhenOnlyNonViewerPanesExist() {
        let terminalID = UUID()
        let layout = LayoutNode.split(
            direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: terminalID)),
                .pane(.note(noteID: UUID())),
            ],
            ratios: [0.5, 0.5]
        )

        let result = toggleTranscript(into: layout, terminalID: terminalID, fromPaneID: terminalID)

        #expect(result.replaced == nil, "note panes are not viewer-class — must split")
        #expect(result.layout.allPaneIDs().count == 3)
        #expect(result.layout.firstPaneID(where: { isLiveTranscriptPane($0, for: terminalID) }) != nil)
    }
}
