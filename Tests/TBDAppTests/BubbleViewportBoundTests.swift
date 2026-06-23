import AppKit
import STTextView
import Testing
@testable import TBDApp

/// Guards the #129 scroll-LAG fix: the chat-bubble overlay must do O(visible)
/// work per draw, NOT O(document). The lag came from enumerating
/// `.transcriptBubbleRole` AND computing a `boundingRect` for every message on
/// every draw/scroll frame. The fix bounds both to the laid-out viewport via
/// `textViewportLayoutController.viewportRange`.
///
/// This asserts the load-bearing property of that fix: on a tall document laid
/// out in a SMALL viewport, the viewport's character span is a small fraction of
/// the whole document — so a viewport-bounded enumeration touches far fewer
/// messages than a full-document one would.
@MainActor
@Suite("Bubble overlay viewport-bound (#129)")
struct BubbleViewportBoundTests {

    @Test("viewport range covers far fewer characters than the full document")
    func viewportRangeIsBounded() {
        let context = TranscriptCardContext(
            terminalID: nil,
            openTranscriptOverlay: nil,
            navigateToThread: nil,
            appState: nil
        )
        let document = TranscriptDocument(context: context)

        // Many alternating bubbles → a document much taller than a 600pt viewport.
        var nodes: [TranscriptRenderNode] = []
        for i in 0..<60 {
            nodes.append(.makeUserPrompt(id: "u\(i)", text: "Question \(i): walk me through part \(i) of the pipeline in enough detail to wrap across several lines of the content column."))
            nodes.append(.makeAssistantText(id: "a\(i)", text: "Answer \(i): part \(i) converts upstream items into cached render nodes. This paragraph is intentionally long so the card spans several wrapped lines and the document grows well past the viewport height."))
        }

        let scrollView = ReadOnlySTTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? STTextView,
              let contentStorage = textView.textContentManager as? NSTextContentStorage else {
            Issue.record("no STTextView / NSTextContentStorage")
            return
        }
        let storage = contentStorage.textStorage ?? {
            let created = NSTextStorage()
            contentStorage.textStorage = created
            return created
        }()
        document.bind(to: storage)
        document.rebuild(nodes)

        // Small fixed viewport in a window so TextKit2 lays out + reports a
        // viewport range.
        let viewportHeight: CGFloat = 600
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: viewportHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        scrollView.frame = NSRect(x: 0, y: 0, width: 680, height: viewportHeight)
        textView.layoutSubtreeIfNeeded()
        textView.textLayoutManager.textViewportLayoutController.layoutViewport()
        textView.layoutSubtreeIfNeeded()

        let total = storage.length
        #expect(total > 0)

        let controller = textView.textLayoutManager.textViewportLayoutController
        guard let viewportRange = controller.viewportRange else {
            Issue.record("no viewportRange after layout")
            return
        }
        let docStart = contentStorage.documentRange.location
        let lower = contentStorage.offset(from: docStart, to: viewportRange.location)
        let upper = contentStorage.offset(from: docStart, to: viewportRange.endLocation)
        let viewportSpan = upper - lower

        // The viewport must cover a small fraction of the document — the property
        // that keeps the bubble draw O(visible). Half is a very loose ceiling; in
        // practice it is far smaller, but tolerant of layout/font variance in CI.
        #expect(viewportSpan > 0)
        #expect(viewportSpan < total / 2,
                "viewport span \(viewportSpan) should be << total \(total) (O(visible) draw)")
    }
}
