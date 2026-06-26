import AppKit
import Testing
@testable import TBDApp

@MainActor
@Suite("Transcript document builder")
struct TranscriptDocumentBuilderTests {
    private func ctx() -> TranscriptCardContext {
        TranscriptCardContext(terminalID: nil, openTranscriptOverlay: nil, appState: nil)
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

    // MARK: - Chat-bubble role classification (#129)

    @Test("bubbleRole: user prompt → .user")
    func bubbleRoleUser() {
        let node = TranscriptRenderNode.makeUserPrompt(id: "u1", text: "hi")
        #expect(TranscriptDocumentBuilder.bubbleRole(for: node) == .user)
    }

    @Test("bubbleRole: assistant text → .assistant")
    func bubbleRoleAssistant() {
        let node = TranscriptRenderNode.makeAssistantText(id: "a1", text: "hello")
        #expect(TranscriptDocumentBuilder.bubbleRole(for: node) == .assistant)
    }

    @Test("bubbleRole: tool call → .other (no bubble)")
    func bubbleRoleOther() {
        let node = TranscriptRenderNode.makeToolCall(id: "b1", name: "Bash", inputJSON: "{}")
        #expect(TranscriptDocumentBuilder.bubbleRole(for: node) == .other)
    }

    @Test("user fragment stamps .transcriptBubbleRole=user on its body, right-aligned")
    func userBubbleAttributeAndAlignment() {
        let node = TranscriptRenderNode.makeUserPrompt(id: "u1", text: "Please do the thing")
        let frag = TranscriptDocumentBuilder.fragment(for: node, context: ctx())
        var roles: Set<String> = []
        frag.enumerateAttribute(.transcriptBubbleRole, in: NSRange(location: 0, length: frag.length)) { value, _, _ in
            if let raw = value as? String { roles.insert(raw) }
        }
        #expect(roles == ["user"])
        // The body run is right-aligned (mirrors ChatBubbleView's user bubble).
        var sawRight = false
        frag.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: frag.length)) { value, _, _ in
            if let style = value as? NSParagraphStyle, style.alignment == .right { sawRight = true }
        }
        #expect(sawRight)
    }

    @Test("assistant fragment stamps .transcriptBubbleRole=assistant, left-aligned")
    func assistantBubbleAttribute() {
        let node = TranscriptRenderNode.makeAssistantText(id: "a1", text: "Here you go")
        let frag = TranscriptDocumentBuilder.fragment(for: node, context: ctx())
        var roles: Set<String> = []
        frag.enumerateAttribute(.transcriptBubbleRole, in: NSRange(location: 0, length: frag.length)) { value, _, _ in
            if let raw = value as? String { roles.insert(raw) }
        }
        #expect(roles == ["assistant"])
        // No run is right-aligned for the assistant block.
        var sawRight = false
        frag.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: frag.length)) { value, _, _ in
            if let style = value as? NSParagraphStyle, style.alignment == .right { sawRight = true }
        }
        #expect(!sawRight)
    }

    @Test("tool call fragment carries NO bubble-role attribute")
    func toolCallNoBubbleAttribute() {
        let node = TranscriptRenderNode.makeToolCall(id: "b1", name: "Bash", inputJSON: #"{"command":"ls"}"#)
        let frag = TranscriptDocumentBuilder.fragment(for: node, context: ctx())
        var sawRole = false
        frag.enumerateAttribute(.transcriptBubbleRole, in: NSRange(location: 0, length: frag.length)) { value, _, _ in
            if value != nil { sawRole = true }
        }
        #expect(!sawRole)
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
