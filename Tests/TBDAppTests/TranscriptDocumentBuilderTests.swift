import AppKit
import Testing
@testable import TBDApp

@MainActor
@Suite("Transcript document builder")
struct TranscriptDocumentBuilderTests {
    private func ctx() -> TranscriptCardContext {
        TranscriptCardContext(terminalID: nil, openTranscriptOverlay: nil, navigateToThread: nil, appState: nil)
    }

    @Test("assistant chat bubble renders header + markdown body")
    func assistantBody() {
        let node = TranscriptRenderNode.makeAssistantText(id: "a1", text: "Use **bold** now")
        let frag = TranscriptDocumentBuilder.fragment(for: node, context: ctx())
        #expect(frag.string.contains("Claude"))
        #expect(frag.string.contains("Use bold now"))
        var foundBold = false
        frag.enumerateAttribute(.font, in: NSRange(location: 0, length: frag.length)) { value, _, _ in
            if let font = value as? NSFont,
               font.fontDescriptor.symbolicTraits.contains(.bold) { foundBold = true }
        }
        #expect(foundBold)
    }

    @Test("tool call embeds one card attachment carrying the node id")
    func toolCallAttachment() {
        let node = TranscriptRenderNode.makeToolCall(id: "b9", name: "Bash", inputJSON: #"{"command":"ls"}"#)
        let frag = TranscriptDocumentBuilder.fragment(for: node, context: ctx())
        var attachments: [TranscriptCardAttachment] = []
        frag.enumerateAttribute(.attachment, in: NSRange(location: 0, length: frag.length)) { value, _, _ in
            if let attachment = value as? TranscriptCardAttachment { attachments.append(attachment) }
        }
        #expect(attachments.count == 1)
        #expect(attachments.first?.nodeID == "b9")
    }
}
