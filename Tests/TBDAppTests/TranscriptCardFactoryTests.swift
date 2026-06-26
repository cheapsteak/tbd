import SwiftUI
import Testing
@testable import TBDApp

@MainActor
@Suite("Transcript card factory")
struct TranscriptCardFactoryTests {
    private func ctx() -> TranscriptCardContext {
        TranscriptCardContext(terminalID: nil, openTranscriptOverlay: nil, appState: nil)
    }

    @Test("interactive tool call yields a card")
    func bashCardProduced() {
        let node = TranscriptRenderNode.makeToolCall(id: "t1", name: "Bash", inputJSON: #"{"command":"ls","description":"list"}"#)
        #expect(TranscriptCardFactory.isInteractive(node))
        #expect(TranscriptCardFactory.card(for: node, context: ctx()) != nil)
    }

    @Test("pure-text chat bubble yields no card")
    func chatBubbleNoCard() {
        let node = TranscriptRenderNode.makeAssistantText(id: "a1", text: "hello")
        #expect(!TranscriptCardFactory.isInteractive(node))
        #expect(TranscriptCardFactory.card(for: node, context: ctx()) == nil)
    }
}
