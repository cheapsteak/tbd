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
    private static let diagLog = Logger(subsystem: "com.tbd.app", category: "textkit-pane")

    let context: TranscriptCardContext
    @Binding var atBottom: Bool
    /// Jump-to-bottom request token: incrementing it asks the coordinator to scroll to end.
    let scrollToBottomToken: Int
    let nodesProvider: @MainActor () -> [TranscriptRenderNode]

    func makeCoordinator() -> Coordinator {
        // Diag: log coordinator creation so we can track Coordinator lifecycle vs
        // session rollovers (a fresh Coordinator means PaneIdentity changed). (#129)
        let tidShort = String((context.terminalID?.uuidString ?? "").suffix(4))
        Self.diagLog.debug("coordinator.create term=\(tidShort, privacy: .public)")
        return Coordinator(document: TranscriptDocument(context: context))
    }

    func makeNSView(context ctx: Context) -> NSScrollView {
        let coordinator = ctx.coordinator
        // `ReadOnlySTTextView.scrollableTextView()` builds a `ReadOnlySTTextView`
        // (the factory uses `Self()`), giving us a view that is selectable and
        // copyable but truly read-only — it refuses both drag-to-move-out and
        // drop, which STTextView's `isEditable = false` alone does NOT do. (#129)
        let scrollView = ReadOnlySTTextView.scrollableTextView()
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
        // Adopt STTextView's OWN text storage as the document's backing store so
        // streaming edits mutate the EXACT object STTextView renders (#129, C1).
        // `attributedText =` would copy bytes into a different internal storage,
        // making subsequent incremental edits invisible. Reuse the existing
        // textStorage already wired to STTextView's layout manager; only create
        // one if STTextView didn't (older fallback).
        if let contentStorage = textView.textContentManager as? NSTextContentStorage {
            let textStorage: NSTextStorage
            if let existing = contentStorage.textStorage {
                textStorage = existing
            } else {
                let created = NSTextStorage()
                contentStorage.textStorage = created
                textStorage = created
            }
            coordinator.document.bind(to: textStorage)
            coordinator.document.rebuild(nodes)
        } else {
            // Fallback: no NSTextContentStorage available — install via
            // attributedText (copies; streaming may not render, but keeps
            // correctness on unexpected content-manager types).
            Self.log.debug("textkit.pane.install.fallback no NSTextContentStorage; using attributedText copy")
            coordinator.document.rebuild(nodes)
            textView.attributedText = coordinator.document.storage
        }
        coordinator.previousNodes = nodes
        coordinator.textView = textView
        coordinator.scrollView = scrollView
        coordinator.lastScrollToken = scrollToBottomToken

        // Defer first scroll-to-bottom so layout has a viewport size to resolve against.
        DispatchQueue.main.async {
            textView.scrollToEndOfDocument(nil)
        }
        Self.log.debug("textkit.pane.installed length=\(coordinator.document.length, privacy: .public)")
        // Diag: log NSView installation with initial node count for lifecycle tracing. (#129)
        let tidShort = String((context.terminalID?.uuidString ?? "").suffix(4))
        Self.diagLog.debug("makeNSView term=\(tidShort, privacy: .public) initialNodeCount=\(nodes.count, privacy: .public)")
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
                // DEFER the bottom-pin scroll (mirrors makeNSView's deferred
                // initial scroll). `applyEdit` mutated the adopted storage inside
                // `performEditingTransaction`, but TextKit 2 lays out the newly
                // appended text ASYNCHRONOUSLY. A synchronous
                // `scrollToEndOfDocument` here resolves against the STALE
                // (pre-append) document height, so it stops short of the real new
                // bottom and the viewport never follows the streamed tail. Running
                // it on the next runloop turn lets layout extend the document
                // first, so the scroll reaches the true new end. (#129)
                DispatchQueue.main.async { [weak self] in
                    self?.textView?.scrollToEndOfDocument(nil)
                }
            } else {
                // User has scrolled up — restore position so reading is undisturbed.
                clip.scroll(to: savedOrigin)
                scrollView.reflectScrolledClipView(clip)
            }

            // Recompute atBottom AFTER the edit so the jump-to-bottom button
            // reflects truth — but DEFER it (I1): TextKit 2 layout is async, so
            // reading geometry synchronously right after the edit sees stale
            // frames. Re-read fresh geometry on the next runloop turn. The
            // deferred bottom-pin scroll above is enqueued first, so by the time
            // this block runs the viewport already reflects the post-scroll
            // position. (#129)
            DispatchQueue.main.async { [weak self] in
                guard self != nil, let scrollView = self?.scrollView else { return }
                let freshClip = scrollView.contentView
                let newVisibleMaxY = freshClip.bounds.origin.y + freshClip.bounds.height
                let newDocMaxY = scrollView.documentView?.frame.maxY ?? newVisibleMaxY
                atBottom.wrappedValue = TranscriptStreamPlan.isNearBottom(
                    documentMaxY: newDocMaxY,
                    visibleMaxY: newVisibleMaxY
                )
            }
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
        /// For `.rebuild` (structural divergence), mutate the adopted storage in
        /// place inside a `performEditingTransaction` — the document's storage IS
        /// the rendered storage (after `bind`), so `document.rebuild` repopulates
        /// the exact bytes STTextView lays out. No `attributedText =` reassignment.
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
                storage.performEditingTransaction {
                    document.rebuild(nodes)
                }
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

// MARK: - ReadOnlySTTextView

/// A truly read-only `STTextView`: selectable and copyable, but it can neither
/// be dragged-to-move-out nor be a drop target.
///
/// `STTextView.isEditable = false` is NOT sufficient. STTextView wires its
/// drag-and-drop machinery to `isSelectable`, not `isEditable`:
///
/// - A `DragSelectedTextGestureRecognizer` is added in `init` with
///   `isEnabled = isSelectable`, so a long-press over the selection begins a
///   real `NSDraggingSession` (`STTextView+DragGestureRecognizer.swift`).
/// - As an `NSDraggingSource`, `sourceOperationMaskFor` returns `.move` for
///   in-application drags (`STTextView+NSDraggingSource.swift`).
/// - As the drop destination, `performDragOperation` calls
///   `performInternalDragOperation`, which DELETES the source range and
///   re-inserts it at the drop point — mutating the document
///   (`STTextView+NSDraggingDestination.swift`). None of this checks
///   `isEditable`.
///
/// We neutralize both ends: disable the drag-out gesture recognizer (so a drag
/// session never begins) and unregister dragged types at construction, and
/// override the `open` drop-destination seams so any residual drop is a no-op.
/// This keeps text selection + copy fully working. (#129)
final class ReadOnlySTTextView: STTextView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // STTextView's `init` adds the press-to-drag recognizer and registers
        // dragged types; `super.init` has now run, so undo both here.
        for recognizer in gestureRecognizers where recognizer is NSPressGestureRecognizer {
            recognizer.isEnabled = false
        }
        unregisterDraggedTypes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Refuse every drop (defense in depth in case dragged types are
    // re-registered by a later STTextView code path): no MOVE / COPY into the
    // read-only document.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
}
