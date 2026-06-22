import AppKit
import STTextView
import Testing
@testable import TBDApp

/// Regression coverage for #129 C1: streaming edits MUST mutate the exact
/// `NSTextStorage` that STTextView renders. Before the fix the document
/// installed its storage via `textView.attributedText =`, which COPIES bytes
/// into STTextView's own internal `NSTextContentStorage.textStorage` — a
/// DIFFERENT object than `document.storage`. The streaming `append`/`updateLast`
/// path then mutated the orphaned copy, so streamed text never rendered.
///
/// These tests bind a `TranscriptDocument` to STTextView's OWN content-storage
/// `textStorage` (exactly as `makeNSView` does), drive an `.append` the SAME WAY
/// `applyEdit` does (through the document inside `performEditingTransaction`),
/// and assert against the RENDERED storage — the object STTextView lays out.
@MainActor
@Suite("STTextView storage adoption (#129 C1)")
struct STTextViewStorageAdoptionTests {

    private func ctx() -> TranscriptCardContext {
        TranscriptCardContext(terminalID: nil, openTranscriptOverlay: nil, navigateToThread: nil, appState: nil)
    }

    /// Build a headless STTextView and return it together with its own
    /// content-storage `NSTextStorage` — the object it renders.
    private func makeTextView() -> (STTextView, NSTextContentStorage, NSTextStorage)? {
        let scrollView = STTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? STTextView,
              let contentStorage = textView.textContentManager as? NSTextContentStorage
        else { return nil }
        let textStorage: NSTextStorage
        if let existing = contentStorage.textStorage {
            textStorage = existing
        } else {
            let created = NSTextStorage()
            contentStorage.textStorage = created
            textStorage = created
        }
        return (textView, contentStorage, textStorage)
    }

    @Test("bind makes document.storage the SAME object STTextView renders")
    func bindAdoptsRenderedStorage() throws {
        let (_, _, rendered) = try #require(makeTextView())
        let doc = TranscriptDocument(context: ctx())
        doc.bind(to: rendered)

        // Object identity: the core invariant. The document mutates the exact
        // storage STTextView lays out.
        #expect(doc.storage === rendered)

        doc.rebuild([.makeAssistantText(id: "a1", text: "first node text")])
        #expect(doc.storage === rendered)
        #expect(rendered.string.contains("first node text"))
    }

    @Test("streaming append renders in STTextView's own storage (would have caught C1)")
    func streamingAppendVisibleInRenderedStorage() throws {
        let (textView, contentStorage, rendered) = try #require(makeTextView())
        let doc = TranscriptDocument(context: ctx())

        // Install exactly as makeNSView does: adopt + rebuild with one node.
        doc.bind(to: rendered)
        doc.rebuild([.makeAssistantText(id: "a1", text: "first node text")])

        // Drive an `.append` THE SAME WAY applyEdit does: through the document,
        // inside the content storage's performEditingTransaction.
        contentStorage.performEditingTransaction {
            doc.append(.makeAssistantText(id: "a2", text: "second node text"))
        }

        // Assert against STTextView's OWN storage — the object it renders, NOT
        // document.storage (which here is the same object, the whole point).
        let renderedStorage = try #require((textView.textContentManager as? NSTextContentStorage)?.textStorage)
        #expect(renderedStorage === rendered)
        #expect(renderedStorage.string.contains("first node text"))
        #expect(renderedStorage.string.contains("second node text"))
    }

    @Test("append grows the adopted storage object's length")
    func appendGrowsAdoptedStorageLength() throws {
        let (_, contentStorage, rendered) = try #require(makeTextView())
        let doc = TranscriptDocument(context: ctx())
        doc.bind(to: rendered)
        doc.rebuild([.makeAssistantText(id: "a1", text: "first")])

        let lengthBefore = rendered.length
        contentStorage.performEditingTransaction {
            doc.append(.makeAssistantText(id: "a2", text: "second"))
        }
        #expect(rendered.length > lengthBefore)
        #expect(doc.length == rendered.length)
    }
}
