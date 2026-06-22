import AppKit
import Testing
@testable import TBDApp

@MainActor
@Suite("Transcript document")
struct TranscriptDocumentTests {
    private func ctx() -> TranscriptCardContext {
        TranscriptCardContext(terminalID: nil, openTranscriptOverlay: nil, navigateToThread: nil, appState: nil)
    }

    @Test("append grows length and records the node range; earlier ranges stable")
    func appendStable() {
        let doc = TranscriptDocument(context: ctx())
        doc.append(.makeAssistantText(id: "a1", text: "first"))
        let firstRange = doc.range(forNodeID: "a1")!
        let lenAfterFirst = doc.length
        doc.append(.makeAssistantText(id: "a2", text: "second"))
        #expect(doc.length > lenAfterFirst)
        #expect(doc.range(forNodeID: "a1") == firstRange)        // unchanged
        #expect(doc.range(forNodeID: "a2")!.location == lenAfterFirst)
        #expect(doc.nodeIDs == ["a1", "a2"])
        #expect(doc.storage.string.contains("first") && doc.storage.string.contains("second"))
    }

    @Test("rebuild resets the document with a fresh set of nodes")
    func rebuildResetsDocument() {
        let doc = TranscriptDocument(context: ctx())
        doc.append(.makeAssistantText(id: "old1", text: "old content"))
        doc.rebuild([
            .makeAssistantText(id: "n1", text: "rebuilt first"),
            .makeAssistantText(id: "n2", text: "rebuilt second")
        ])
        #expect(doc.range(forNodeID: "old1") == nil)
        #expect(doc.nodeIDs == ["n1", "n2"])
        #expect(doc.storage.string.contains("rebuilt first"))
        #expect(doc.storage.string.contains("rebuilt second"))
        #expect(doc.length == doc.storage.length)
    }

    @Test("length is always in sync with storage.length")
    func lengthInSync() {
        let doc = TranscriptDocument(context: ctx())
        #expect(doc.length == doc.storage.length)
        doc.append(.makeAssistantText(id: "x1", text: "hello"))
        #expect(doc.length == doc.storage.length)
        doc.append(.makeAssistantText(id: "x2", text: "world"))
        #expect(doc.length == doc.storage.length)
    }

    @Test("append same id twice does not duplicate in order")
    func appendSameIDNoDuplicate() {
        let doc = TranscriptDocument(context: ctx())
        doc.append(.makeAssistantText(id: "dup", text: "first"))
        doc.append(.makeAssistantText(id: "dup", text: "second"))
        // order must not contain "dup" twice
        #expect(doc.nodeIDs.filter { $0 == "dup" }.count == 1)
    }

    @Test("updateLast re-renders only the tail node; earlier ranges unchanged")
    func updateTail() {
        let doc = TranscriptDocument(context: ctx())
        doc.append(.makeAssistantText(id: "a1", text: "frozen"))
        let frozenRange = doc.range(forNodeID: "a1")!
        doc.append(.makeAssistantText(id: "a2", text: "stream"))
        doc.updateLast(.makeAssistantText(id: "a2", text: "streamed more text"))
        #expect(doc.range(forNodeID: "a1") == frozenRange)            // earlier node untouched
        #expect(doc.storage.string.contains("frozen"))
        #expect(doc.storage.string.contains("streamed more text"))
        #expect(!doc.storage.string.contains("stream\n"))             // old tail text replaced
        #expect(doc.range(forNodeID: "a2")!.location == frozenRange.location + frozenRange.length)
        #expect(doc.length == doc.storage.length)
    }

    @Test("updateLast with non-tail id falls back to append")
    func updateLastFallsBackToAppend() {
        let doc = TranscriptDocument(context: ctx())
        doc.append(.makeAssistantText(id: "a1", text: "first"))
        doc.append(.makeAssistantText(id: "a2", text: "second"))
        // a1 is NOT the tail; updateLast should fall back to append
        let lenBefore = doc.length
        doc.updateLast(.makeAssistantText(id: "a1", text: "this should not replace"))
        // Since a1 is not the tail, it falls back to append — length grows
        // and a1 now has an updated range (it was re-appended, overwriting old range)
        #expect(doc.length > lenBefore)
        #expect(doc.length == doc.storage.length)
    }

    @Test("updateLast on empty document falls back to append")
    func updateLastOnEmpty() {
        let doc = TranscriptDocument(context: ctx())
        doc.updateLast(.makeAssistantText(id: "a1", text: "initial"))
        #expect(doc.nodeIDs == ["a1"])
        #expect(doc.length == doc.storage.length)
        #expect(doc.length > 0)
    }
}
