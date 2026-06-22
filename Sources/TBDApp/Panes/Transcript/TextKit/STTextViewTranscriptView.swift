import AppKit
import STTextView
import SwiftUI
import os

/// TextKit 2 live-transcript renderer: a single selectable `STTextView` whose
/// document is owned by a `TranscriptDocument`. Plain `NSTextView` does NOT drive
/// `NSTextAttachmentViewProvider`s — STTextView is required to place the embedded
/// SwiftUI card attachments (#129, synthesis §3).
@MainActor
struct STTextViewTranscriptView: NSViewRepresentable {
    private static let log = Logger(subsystem: "com.tbd.app", category: "perf-transcript")

    let context: TranscriptCardContext
    @Binding var atBottom: Bool
    /// Jump-to-bottom request token: incrementing it asks the coordinator to scroll to end.
    let scrollToBottomToken: Int
    let nodesProvider: @MainActor () -> [TranscriptRenderNode]

    func makeCoordinator() -> Coordinator {
        Coordinator(document: TranscriptDocument(context: context))
    }

    func makeNSView(context ctx: Context) -> NSScrollView {
        let coordinator = ctx.coordinator
        let scrollView = STTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? STTextView else { return scrollView }

        textView.isEditable = false
        textView.isSelectable = true
        // Line wrapping: STTextView defaults to isHorizontallyResizable = true (no wrap).
        // Setting false makes the text container track the viewport width so prose
        // wraps to the visible width and re-wraps on resize.
        textView.isHorizontallyResizable = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let nodes = nodesProvider()
        coordinator.document.rebuild(nodes)
        coordinator.previousNodes = nodes
        // Install the document's storage as the text view's content ONCE.
        // After this, all mutations go through TranscriptDocument and are
        // wrapped in performEditingTransaction so TextKit 2 sees incremental edits.
        textView.attributedText = coordinator.document.storage
        coordinator.textView = textView
        coordinator.scrollView = scrollView
        coordinator.lastScrollToken = scrollToBottomToken

        // Defer first scroll-to-bottom so layout has a viewport size to resolve against.
        DispatchQueue.main.async {
            textView.scrollToEndOfDocument(nil)
        }
        Self.log.debug("textkit.pane.installed length=\(coordinator.document.length, privacy: .public)")
        return scrollView
    }

    /// This is the flush trigger — NOT a full rebuild.
    ///
    /// `flush` diffs via `TranscriptStreamPlan` and returns `.noop` or a small
    /// `.append`/`.updateLast` on each SwiftUI update pass, making it cheap to
    /// call here on every update. The forbidden thing is an unconditional
    /// `document.rebuild` / full reinstall.
    func updateNSView(_ nsView: NSScrollView, context ctx: Context) {
        let coordinator = ctx.coordinator
        if scrollToBottomToken != coordinator.lastScrollToken {
            coordinator.lastScrollToken = scrollToBottomToken
            coordinator.textView?.scrollToEndOfDocument(nil)
        }
        coordinator.flush(nodes: nodesProvider(), atBottom: $atBottom)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        let document: TranscriptDocument
        weak var textView: STTextView?
        weak var scrollView: NSScrollView?
        var previousNodes: [TranscriptRenderNode] = []
        var lastScrollToken = 0

        private static let log = Logger(subsystem: "com.tbd.app", category: "perf-transcript")

        init(document: TranscriptDocument) { self.document = document }

        /// Apply a new poll result to the live document with a before-edit
        /// bottom-pin. Pure decision in `TranscriptStreamPlan`; here we only do
        /// the TextKit mutation + scroll bookkeeping. (#129)
        func flush(nodes: [TranscriptRenderNode], atBottom: Binding<Bool>) {
            guard let textView, let scrollView else { return }
            let step = TranscriptStreamPlan.step(previous: previousNodes, next: nodes)
            guard step != .noop else {
                previousNodes = nodes
                return
            }

            // Capture bottom-pin state BEFORE the edit: document height grows on
            // edit so a post-edit check would misjudge whether the user was at bottom.
            let clip = scrollView.contentView
            let visibleMaxY = clip.bounds.origin.y + clip.bounds.height
            let docMaxY = scrollView.documentView?.frame.maxY ?? visibleMaxY
            let wasAtBottom = TranscriptStreamPlan.isNearBottom(documentMaxY: docMaxY, visibleMaxY: visibleMaxY)
            let savedOrigin = clip.bounds.origin

            let interval = TranscriptSignposts.signposter.beginInterval("transcript.document.append")
            applyEdit(step: step, nodes: nodes, textView: textView)
            TranscriptSignposts.signposter.endInterval("transcript.document.append", interval)

            previousNodes = nodes

            if wasAtBottom {
                textView.scrollToEndOfDocument(nil)
            } else {
                // User has scrolled up — restore position so reading is undisturbed.
                clip.scroll(to: savedOrigin)
                scrollView.reflectScrolledClipView(clip)
            }

            // Recompute atBottom after the edit so the jump-to-bottom button reflects truth.
            let newVisibleMaxY = clip.bounds.origin.y + clip.bounds.height
            let newDocMaxY = scrollView.documentView?.frame.maxY ?? newVisibleMaxY
            atBottom.wrappedValue = TranscriptStreamPlan.isNearBottom(
                documentMaxY: newDocMaxY,
                visibleMaxY: newVisibleMaxY
            )
        }

        /// Apply a `TranscriptStreamStep` to the document.
        ///
        /// NEVER call `STTextView.replaceCharacters` directly: that path ends in
        /// `didChangeText()` which installs a `postLayoutAction` that calls
        /// `scrollToVisible(selection)`. Our selection sits at document location 0
        /// (set by the `attributedText` installer), so every direct replace yanks
        /// the viewport to the TOP. Instead, route all mutation through
        /// `TranscriptDocument` methods inside `performEditingTransaction` — TextKit 2
        /// gets notified and re-lays out only the changed tail, with no
        /// selection-driven scroll side effect. (#129, spike `:312-340`)
        ///
        /// For `.rebuild` (structural divergence), reinstall via
        /// `textView.attributedText = document.storage` (full reset; acceptable on
        /// the rare rebuild path — matches the SwiftUI `transcript.swap`).
        private func applyEdit(
            step: TranscriptStreamStep,
            nodes: [TranscriptRenderNode],
            textView: STTextView
        ) {
            guard let storage = textView.textContentManager as? NSTextContentStorage else {
                // Fallback: direct reinstall (rare; keeps correctness if the content
                // manager is not the expected type).
                document.rebuild(nodes)
                textView.attributedText = document.storage
                return
            }
            switch step {
            case .noop:
                return
            case .rebuild:
                document.rebuild(nodes)
                textView.attributedText = document.storage
            case let .append(fromIndex):
                storage.performEditingTransaction {
                    for node in nodes[fromIndex...] { document.append(node) }
                }
            case .updateLast:
                storage.performEditingTransaction {
                    if let last = nodes.last { document.updateLast(last) }
                }
            }
        }
    }
}
