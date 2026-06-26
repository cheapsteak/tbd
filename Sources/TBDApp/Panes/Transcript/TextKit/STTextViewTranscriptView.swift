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

        // Pin the initial open to the TRUE bottom (newest message), like the old
        // pane's `.defaultScrollAnchor(.bottom)`. A SINGLE deferred
        // `scrollToEndOfDocument` is NOT enough on a long transcript: TextKit2
        // lays the document out ASYNCHRONOUSLY, so the first scroll resolves
        // against an incomplete (too-short) document height and stops partway. We
        // converge on the realized TAIL fragment's position via the
        // viewport-relative bottom-stick (O(visible) per iteration) — it lands on
        // the newest content instead of chasing the jittery absolute document-
        // height estimate the old absolute-maxY retry did (which parked ~500pt
        // short on this long session and cost ~2s). (#129)
        coordinator.scrollViewportToEnd()
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
            // Jump-to-bottom button: converge on the realized tail so the newest
            // content actually lands on screen (a single scrollToEndOfDocument
            // parks short on a long doc, same as the initial-open bug). (#129)
            coordinator.scrollViewportToEnd()
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

        /// Scrolls to the TRUE document bottom, retrying across runloop turns
        /// until the clip view actually reaches the document's max-Y or we run out
        /// of attempts. TextKit2 extends the document height asynchronously, so a
        /// single `scrollToEndOfDocument` on a long transcript parks partway; each
        /// retry re-reads the (now taller) document and scrolls again until the
        /// position is stable. (#129)
        func scrollToTrueBottom(attempts: Int) {
            guard attempts > 0, let textView, scrollView != nil else { return }
            textView.scrollToEndOfDocument(nil)
            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = self.scrollView else { return }
                let clip = scrollView.contentView
                let visibleMaxY = clip.bounds.origin.y + clip.bounds.height
                let docMaxY = scrollView.documentView?.frame.maxY ?? visibleMaxY
                // Stop once parked at the true bottom (within 1pt); otherwise the
                // document likely grew from async layout — try again.
                if docMaxY - visibleMaxY > 1 {
                    self.scrollToTrueBottom(attempts: attempts - 1)
                }
            }
        }

        /// Bottom-stick that does NOT chase the unstable ABSOLUTE document height,
        /// and converges ACROSS runloop turns so TextKit 2's async layout can
        /// actually advance between attempts.
        ///
        /// TextKit 2 only ever lays out the realized viewport, so the document's
        /// total height is an ESTIMATE that converges (jitters smaller→larger) as
        /// more fragments get incidentally laid out. The old `scrollToTrueBottom`
        /// retried while `documentView.frame.maxY - visibleMaxY > 1`, chasing that
        /// estimate to zero — on a long transcript it never closes and the retries
        /// exhaust mid-document (the #129 open bug).
        ///
        /// A SYNCHRONOUS convergence loop (all iterations in ONE runloop turn) is
        /// ALSO wrong: `scrollToEndOfDocument` schedules viewport layout on the
        /// runloop, so back-to-back iterations in the same turn all read the SAME
        /// not-yet-advanced layout — the loop "converges" on an incomplete estimate
        /// and parks mid-document. So we run each convergence attempt on a SEPARATE
        /// runloop turn (`DispatchQueue.main.async`), the way the old
        /// `scrollToTrueBottom(attempts:)` did, letting AppKit/TextKit2 perform a
        /// layout pass between attempts.
        ///
        /// Each turn drives STTextView's own Apple-blessed cheap path
        /// (`scrollToEndOfDocument` = `relocateViewport(to:endLocation)` →
        /// `layoutViewport` → `updateContentSizeIfNeeded` → scroll, all O(visible))
        /// then asks the viewport-relative question that actually matters: is the
        /// realized LAST text layout fragment's bottom now WITHIN the visible clip
        /// rect? On a long transcript a single `scrollToEndOfDocument` parks ~200pt
        /// short — it resolves against a content size that only grows on the NEXT
        /// async layout pass, so the tail sits just below the visible bottom. While
        /// that gap remains (and turns remain) we schedule another turn so the
        /// freshly-grown content size lets the next cheap scroll reach further. We
        /// also stop if the tail's position stops moving AND we can't close the gap
        /// (genuinely no more layout to do). NEVER `sizeToFit()` /
        /// `ensureLayout(documentRange)` — those are O(document) (~2.35s freeze). (#129)
        func scrollViewportToEnd(
            maxTurns: Int = 10,
            gapThreshold: CGFloat = 2.0,
            stabilityThreshold: CGFloat = 1.0
        ) {
            guard let textView, let scrollView else { return }

            // Cheap viewport realization + scroll to the realized tail THIS turn.
            textView.scrollToEndOfDocument(nil)
            scrollView.reflectScrolledClipView(scrollView.contentView)

            // Measure the realized LAST fragment's bottom (viewport-relative,
            // O(visible)) by reverse-enumerating from the document end and taking
            // the first (newest) fragment.
            let tailMaxY = realizedTailMaxY(textView: textView)

            // Schedule the convergence check on the NEXT runloop turn so async
            // layout can advance (and grow the content size) before we re-measure.
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, let scrollView = self.scrollView else { return }

                // Re-scroll against the (possibly grown) content size, then measure.
                textView.scrollToEndOfDocument(nil)
                scrollView.reflectScrolledClipView(scrollView.contentView)

                let newTailMaxY = self.realizedTailMaxY(textView: textView)
                let clip = scrollView.contentView
                let visibleMaxY = clip.bounds.origin.y + clip.bounds.height

                // Done when the realized tail is at/above the visible bottom (the
                // newest content is on screen). `gap > 0` means the tail still sits
                // below the viewport — `scrollToEndOfDocument` parked short.
                let gap = (newTailMaxY ?? visibleMaxY) - visibleMaxY
                let tailVisible = gap <= gapThreshold

                // Whether layout is still advancing the tail position between turns.
                let stillMoving: Bool
                if let tailMaxY, let newTailMaxY {
                    stillMoving = abs(newTailMaxY - tailMaxY) >= stabilityThreshold
                } else {
                    stillMoving = true
                }

                // Keep converging while the tail is below the viewport AND there's
                // either remaining movement or turns left to let layout catch up.
                if !tailVisible, stillMoving, maxTurns > 1 {
                    self.scrollViewportToEnd(
                        maxTurns: maxTurns - 1,
                        gapThreshold: gapThreshold,
                        stabilityThreshold: stabilityThreshold
                    )
                    return
                }

                // Settled (tail visible, no more movement, or capped). One more
                // cheap scroll, then close any residual gap directly: STTextView's
                // `scrollToEndOfDocument` can park ~200pt short of the bottom even
                // once the documentView has grown to its full height (its target is
                // computed from a content size that lags the realized layout). Since
                // the documentView frame is now correct, pin the clip to the true
                // bottom in O(1) — clamp the origin to `documentView.maxY -
                // viewportHeight` — rather than chasing it with more layout passes.
                textView.scrollToEndOfDocument(nil)
                self.pinClipToDocumentBottom(scrollView: scrollView)
            }
        }

        /// The realized LAST text layout fragment's `layoutFragmentFrame.maxY`
        /// (viewport-relative, O(visible)). Reverse-enumerates from the document
        /// end and returns the first (newest) fragment's bottom, or `nil` if none
        /// is laid out yet.
        private func realizedTailMaxY(textView: STTextView) -> CGFloat? {
            let layoutManager = textView.textLayoutManager
            var tailMaxY: CGFloat?
            layoutManager.enumerateTextLayoutFragments(
                from: layoutManager.documentRange.endLocation,
                options: [.reverse, .ensuresLayout]
            ) { fragment in
                tailMaxY = fragment.layoutFragmentFrame.maxY
                return false  // first (last-in-document) fragment only
            }
            return tailMaxY
        }

        /// Pins the clip view to the document's true bottom in O(1): clamps the
        /// scroll origin to `documentView.frame.maxY - viewportHeight`. Used as the
        /// final step of the convergence so the newest content lands at the viewport
        /// bottom even when `scrollToEndOfDocument` parked short of it. Only ever
        /// scrolls DOWN (never above the cheap scroll's resting place), so it can't
        /// yank the viewport up if the document is shorter than the viewport. (#129)
        private func pinClipToDocumentBottom(scrollView: NSScrollView) {
            guard let documentView = scrollView.documentView else { return }
            let clip = scrollView.contentView
            let viewportHeight = clip.bounds.height
            let targetY = max(0, documentView.frame.maxY - viewportHeight)
            // Only move down toward the bottom — never above where the cheap scroll
            // already left us.
            guard targetY > clip.bounds.origin.y else {
                scrollView.reflectScrolledClipView(clip)
                return
            }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: targetY))
            scrollView.reflectScrolledClipView(clip)
        }

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

            // Repaint bubble chrome. TextKit 2 lays out the changed range
            // asynchronously — a synchronous setBubblesNeedDisplay() here would
            // call enumerateTextSegments on not-yet-laid-out ranges and draw
            // nothing useful (stale or empty rects). Defer so the overlay
            // repaints only after layout has settled on the next runloop turn. (#129)
            DispatchQueue.main.async { [weak textView] in
                (textView as? ReadOnlySTTextView)?.setBubblesNeedDisplay()
            }

            if wasAtBottom {
                // DEFER the bottom-pin scroll (mirrors makeNSView's deferred
                // initial scroll). `applyEdit` mutated the adopted storage inside
                // `performEditingTransaction`, but TextKit 2 lays out the newly
                // appended text ASYNCHRONOUSLY. A synchronous
                // `scrollToEndOfDocument` here resolves against the STALE
                // (pre-append) document height, so it stops short of the real new
                // bottom and the viewport never follows the streamed tail. Running
                // it on the next runloop turn lets layout extend the document
                // first, so the convergence loop reaches the true new end. Use the
                // viewport-relative bottom-stick (not a single scrollToEndOfDocument)
                // so streaming stays pinned to the realized tail. (#129)
                DispatchQueue.main.async { [weak self] in
                    self?.scrollViewportToEnd()
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

// MARK: - BubbleBackgroundView

/// Draws chat-bubble chrome BEHIND the transcript text: a right-aligned filled
/// blue bubble for each user prompt and a full-width bordered rounded card for
/// each assistant message, mirroring `ChatBubbleView`. It owns no text — it
/// scans the OWNING text view's rendered storage for `.transcriptBubbleRole`
/// runs and asks the `NSTextLayoutManager` for each run's on-screen rect every
/// draw pass, so it stays correct across streaming edits and rebuilds without a
/// side reference to the document. Carrying the role in the attributed string
/// means any path rendering the same storage (including the headless visual
/// harness) draws identical bubbles. (#129)
@MainActor
final class BubbleBackgroundView: NSView {
    private weak var textView: STTextView?

    /// Internal padding between a block's text and its drawn bubble edge,
    /// matching `ChatBubbleView`'s ~11pt horizontal / 8pt vertical chrome insets.
    /// Shared with the right-aligned user paragraph's `tailIndent` so the bubble's
    /// right edge lands exactly one padding outside the (inset) text. (#129)
    private let hInset: CGFloat = BubbleRole.horizontalPadding
    /// Interior vertical padding between a bubble's body text and the drawn card
    /// edge, matching `ChatBubbleView`'s 8pt top/bottom chrome inset. The header
    /// label sits ABOVE the card (`BubbleRole.headerBodyGap` of clearance is
    /// reserved by the body paragraph's `paragraphSpacingBefore`), so this inset
    /// never rises into the header. (#129)
    private let vInset: CGFloat = 8
    private let cornerRadius: CGFloat = 10

    init(textView: STTextView?) {
        self.textView = textView
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Wires the owning text view after `super.init` (when `self` is available).
    func adopt(textView: STTextView) {
        self.textView = textView
    }

    // Flipped so segment frames (top-left origin, in text-view coordinates) map
    // straight through without a y-flip.
    override var isFlipped: Bool { true }

    // Bubbles are purely decorative; never intercept clicks/selection.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let textView,
              let contentStorage = textView.textContentManager as? NSTextContentStorage,
              let storage = contentStorage.textStorage else { return }
        let layoutManager = textView.textLayoutManager

        let userFill = NSColor.controlAccentColor.withAlphaComponent(0.15)
        let assistantFill = NSColor.controlBackgroundColor
        let assistantStroke = NSColor.separatorColor

        // Bound ALL work to the laid-out viewport. Enumerating
        // `.transcriptBubbleRole` over the whole document AND computing a
        // `boundingRect` (via `enumerateTextSegments`) for every message on every
        // draw/scroll frame is O(N) and was the scroll LAG on long transcripts.
        // It also produced OVERLAP: `enumerateTextSegments` for ranges outside the
        // current viewport returns stale / transitional frames mid-scroll, so a
        // bubble drawn for an off-screen message landed in the wrong place. We
        // enumerate and compute rects ONLY for the character range backing the
        // currently laid-out viewport (extended by a margin so a bubble straddling
        // the viewport edge still draws). (#129)
        guard let scanRange = visibleScanRange(textView: textView,
                                               contentStorage: contentStorage,
                                               storage: storage) else { return }

        storage.enumerateAttribute(.transcriptBubbleRole, in: scanRange, options: []) { value, runRange, _ in
            // The role run may extend past the scan window (a tall message that
            // straddles the viewport top/bottom); compute the rect over the FULL
            // role run so the card spans the whole message, but only because the
            // run intersects the visible window.
            guard let raw = value as? String, let role = BubbleRole(attributeValue: raw),
                  runRange.length > 0,
                  let textRange = textRange(for: runRange, in: contentStorage),
                  var rect = boundingRect(of: textRange, layoutManager: layoutManager) else { return }

            // Grow the tight text union out to the bubble's chrome insets.
            rect = rect.insetBy(dx: -hInset, dy: -vInset)
            // Keep within the drawing bounds horizontally so the rounded edge is
            // never clipped flat against the view edge.
            rect.origin.x = max(rect.origin.x, 1)
            if rect.maxX > bounds.width - 1 {
                rect.size.width = bounds.width - 1 - rect.origin.x
            }

            // Skip bubbles outside the dirty region — cheap final cull now that
            // enumeration itself is already bounded to the viewport. (#129)
            guard rect.intersects(dirtyRect) else { return }

            let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            switch role {
            case .user:
                userFill.setFill()
                path.fill()
            case .assistant:
                assistantFill.setFill()
                path.fill()
                path.lineWidth = 1
                assistantStroke.setStroke()
                path.stroke()
            case .other:
                break
            }
        }
    }

    /// Character `NSRange` backing the currently laid-out viewport, extended by a
    /// margin on each side so a bubble straddling the viewport edge still draws.
    /// `nil` if the viewport range is unavailable (nothing laid out yet). This is
    /// what keeps the draw O(visible) rather than O(document). (#129)
    private func visibleScanRange(
        textView: STTextView,
        contentStorage: NSTextContentStorage,
        storage: NSTextStorage
    ) -> NSRange? {
        let controller = textView.textLayoutManager.textViewportLayoutController
        guard let viewportRange = controller.viewportRange else { return nil }
        let docStart = contentStorage.documentRange.location
        let lower = contentStorage.offset(from: docStart, to: viewportRange.location)
        let upper = contentStorage.offset(from: docStart, to: viewportRange.endLocation)
        guard lower >= 0, upper >= lower else { return nil }
        // Margin (in characters) so a message whose body starts just above the
        // viewport top — or continues just below the bottom — is still picked up
        // and its bubble drawn. Generous but still O(visible).
        let margin = 4_000
        let clampedLower = max(0, lower - margin)
        let clampedUpper = min(storage.length, upper + margin)
        return NSRange(location: clampedLower, length: clampedUpper - clampedLower)
    }

    /// Converts a character `NSRange` into a TextKit 2 `NSTextRange` via the
    /// content manager's document-start offset arithmetic.
    private func textRange(for range: NSRange, in contentManager: NSTextContentManager) -> NSTextRange? {
        let docStart = contentManager.documentRange.location
        guard let start = contentManager.location(docStart, offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// Unions the standard text segment frames over `textRange` to a single
    /// bounding rect (in text-view coordinates), or `nil` if no segments laid out.
    private func boundingRect(of textRange: NSTextRange, layoutManager: NSTextLayoutManager) -> CGRect? {
        var union: CGRect?
        layoutManager.enumerateTextSegments(
            in: textRange,
            type: .standard,
            options: .rangeNotRequired
        ) { _, segmentFrame, _, _ in
            union = union.map { $0.union(segmentFrame) } ?? segmentFrame
            return true
        }
        return union
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
    /// Chat-bubble chrome painted BEHIND the text. Inserted as the bottom-most
    /// subview so STTextView's own (clear-backed) content layer lets it show
    /// through under the selectable text. Owned here — not by the representable —
    /// so EVERY path that builds a `ReadOnlySTTextView` (including the headless
    /// visual-compare harness) gets identical bubble drawing. (#129)
    private let bubbleView: BubbleBackgroundView

    override init(frame frameRect: NSRect) {
        bubbleView = BubbleBackgroundView(textView: nil)
        super.init(frame: frameRect)
        bubbleView.adopt(textView: self)
        bubbleView.autoresizingMask = [.width, .height]
        bubbleView.frame = bounds
        // `.below` with a nil sibling puts it at the back of the subview stack,
        // behind STTextView's content/selection views.
        addSubview(bubbleView, positioned: .below, relativeTo: nil)
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

    /// Marks the bubble chrome for repaint. Called after every streaming edit
    /// (the text content changed, so the drawn bubbles must follow).
    func setBubblesNeedDisplay() {
        bubbleView.frame = bounds
        bubbleView.needsDisplay = true
    }

    override func layout() {
        super.layout()
        // Keep the bubble overlay covering the full (scrollable) text extent and
        // repaint as layout settles so bubbles track re-wrapping on resize.
        bubbleView.frame = bounds
        bubbleView.needsDisplay = true
    }

    // Refuse every drop (defense in depth in case dragged types are
    // re-registered by a later STTextView code path): no MOVE / COPY into the
    // read-only document.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
}
