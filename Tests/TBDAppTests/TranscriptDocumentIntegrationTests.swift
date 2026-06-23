import AppKit
import Testing
@testable import TBDApp

@MainActor
@Suite("Transcript document integration")
struct TranscriptDocumentIntegrationTests {

    // MARK: - Helpers

    private func makeContext() -> TranscriptCardContext {
        TranscriptCardContext(
            terminalID: nil,
            openTranscriptOverlay: nil,
            navigateToThread: nil,
            appState: nil
        )
    }

    // MARK: - Tests

    @Test("mixed transcript + streaming tail")
    func mixedAndStreaming() {
        let doc = TranscriptDocument(context: makeContext())

        // ── Build a realistic mixed transcript ──────────────────────────────
        // markdown body includes heading, bold, inline code, fenced code, table
        let mdBody = """
            # Plan
            Use **swift** and `build`

            ```bash
            swift build
            ```

            | A | B |
            |---|---|
            | 1 | 2 |
            """

        doc.rebuild([
            .makeUserPrompt(id: "u1", text: "Run the build"),
            .makeAssistantText(id: "a1", text: mdBody),
            .makeToolCall(id: "b1", name: "Bash", inputJSON: #"{"command":"swift build"}"#),
            .makeToolCall(id: "r1", name: "Read", inputJSON: #"{"file_path":"/x.swift"}"#),
            .makeSubagentSummary(id: "s1", count: 3, agentType: "general-purpose")
        ])

        // (a) document is non-empty
        #expect(doc.length > 0)

        // (b) expected text substrings present
        let text = doc.storage.string
        #expect(text.contains("You"))
        #expect(text.contains("Claude"))
        #expect(text.contains("Plan"))
        #expect(text.contains("swift"))

        // (c) attachments: the Bash + Read tool cards, plus ONE grid-view
        // attachment for the GFM table in the assistant markdown body. The table
        // attachment's nodeID is derived from its source position, so we only
        // assert the tool-card IDs explicitly and the table by prefix. (#129)
        var cards: [TranscriptCardAttachment] = []
        doc.storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: doc.length),
            options: []
        ) { value, _, _ in
            if let attachment = value as? TranscriptCardAttachment {
                cards.append(attachment)
            }
        }
        let toolCardIDs = cards.map(\.nodeID).filter { !$0.hasPrefix("table-") }
        let tableIDs = cards.map(\.nodeID).filter { $0.hasPrefix("table-") }
        #expect(Set(toolCardIDs) == ["b1", "r1"])
        #expect(tableIDs.count == 1)

        // (d) nodeIDs match input order
        #expect(doc.nodeIDs == ["u1", "a1", "b1", "r1", "s1"])

        // ── Streaming sequence ───────────────────────────────────────────────
        // Capture the Read card's range before any tail edits
        let r1Range = doc.range(forNodeID: "r1")
        #expect(r1Range != nil)

        // append a new streaming node, then grow it twice via updateLast
        doc.append(.makeAssistantText(id: "a2", text: "wor"))
        doc.updateLast(.makeAssistantText(id: "a2", text: "working"))
        doc.updateLast(.makeAssistantText(id: "a2", text: "working on it now"))

        // r1's range must be frozen — tail edits only touch the end of the document
        #expect(doc.range(forNodeID: "r1") == r1Range)

        // final streamed text must be visible in storage
        #expect(doc.storage.string.contains("working on it now"))
    }
}
