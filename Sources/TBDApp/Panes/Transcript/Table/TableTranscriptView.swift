import AppKit
import SwiftUI
import TBDShared
import os

/// NSTableView-based live-transcript renderer. Each row hosts the existing
/// SwiftUI `SelectableTranscriptRow` inside an `NSHostingView<AnyView>`,
/// virtualized by AppKit's row reuse. Row heights are measured with the
/// codebase's proven `TranscriptCardSizing.fittingHeight` path
/// (`NSHostingController.sizeThatFits`) and cached keyed by
/// `(node.id, contentVersion, columnWidth)`, so a re-poll never re-measures an
/// unchanged row and a width change invalidates only what it must.
///
/// This replaces the fragile single-document TextKit approach: there is no
/// shared attributed string, no manual viewport bubble drawing — AppKit owns
/// virtualization and selection-highlight suppression. Streaming deltas are
/// classified by the shared `TranscriptStreamPlan` and mapped to minimal table
/// ops (insertRows / reconfigure-last / reloadData) so the common append path
/// never triggers a full reload. (#129)
@MainActor
struct TableTranscriptView: NSViewRepresentable {
    let context: TranscriptCardContext
    @Binding var atBottom: Bool
    /// Jump-to-bottom request token: incrementing it asks the coordinator to
    /// scroll to the last row.
    let scrollToBottomToken: Int
    let nodesProvider: @MainActor () -> [TranscriptRenderNode]

    private static let log = Logger(subsystem: "com.tbd.app", category: "table-transcript")

    func makeCoordinator() -> Coordinator {
        Coordinator(context: context)
    }

    func makeNSView(context ctx: Context) -> NSScrollView {
        let coordinator = ctx.coordinator

        // FIX 1(a): disable AppKit's off-screen row-height ESTIMATION. On Ventura+
        // NSTableView estimates the height of not-yet-realized rows from the rows
        // it has already measured; for a transcript whose row heights vary wildly
        // that guess is far too large, so a row reserves too much space and then
        // visibly shrinks (the collapsing blank gap) when it scrolls into view and
        // `heightOfRow` returns the real height. Turning estimation off forces the
        // table to ask `heightOfRow` for the REAL height of every row up front —
        // which is a pure cache hit because we precompute all heights eagerly
        // (FIX 1(b)). The authoritative register now happens at app launch
        // (`applicationWillFinishLaunching`) so it precedes ANY NSTableView; this
        // redundant register is harmless. `register` (not `set`) means it never
        // persists into the real plist, per repo UserDefaults rules.
        UserDefaults.standard.register(defaults: ["NSTableViewCanEstimateRowHeights": false])

        let tableView = TranscriptBubbleTableView()
        tableView.headerView = nil
        tableView.gridStyleMask = []
        tableView.backgroundColor = .clear
        tableView.usesAutomaticRowHeights = false
        tableView.selectionHighlightStyle = .none
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.style = .plain
        tableView.rowSizeStyle = .custom

        let column = NSTableColumn(identifier: Coordinator.columnID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.dataSource = coordinator
        tableView.delegate = coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        coordinator.tableView = tableView
        coordinator.scrollView = scrollView
        coordinator.lastScrollToken = scrollToBottomToken

        let nodes = nodesProvider()
        coordinator.nodes = nodes
        coordinator.previousNodes = nodes
        // FIX 1(b): eagerly measure + cache EVERY row's exact height before the
        // table asks `heightOfRow`, so the first layout is all cache hits and no
        // row ever reserves a provisional/estimated height.
        coordinator.precomputeAllHeights()
        tableView.reloadData()

        // Pin the initial open to the newest message (last row), deferred so the
        // table has performed its first layout pass and row frames exist.
        DispatchQueue.main.async {
            coordinator.scrollToEnd(animated: false)
        }

        Self.warmHighlightrOnce()

        // One-time runtime verification of FIX 1(a): with the app-launch register
        // in place, `canEstimate` must read false by the time any table is set up.
        Self.log.info(
            "table.estimation canEstimate=\(UserDefaults.standard.bool(forKey: "NSTableViewCanEstimateRowHeights"), privacy: .public) usesAutomaticRowHeights=\(tableView.usesAutomaticRowHeights, privacy: .public)")

        Self.log.debug("table.installed rows=\(nodes.count, privacy: .public)")
        return scrollView
    }

    /// Highlightr's first init costs ~300ms (it loads the full highlight.js
    /// runtime). It's `@MainActor`, so we can't move it off the main thread —
    /// but we can pay it asynchronously at pane install, before the first real
    /// code bubble needs it. Runs exactly once per process.
    private static var didWarmHighlightr = false
    private static func warmHighlightrOnce() {
        guard !didWarmHighlightr else { return }
        didWarmHighlightr = true
        DispatchQueue.main.async {
            _ = MarkdownCodeBlock.attributed(code: "x", language: "swift", theme: .chatBubble)
        }
    }

    func updateNSView(_ nsView: NSScrollView, context ctx: Context) {
        let coordinator = ctx.coordinator
        if scrollToBottomToken != coordinator.lastScrollToken {
            coordinator.lastScrollToken = scrollToBottomToken
            coordinator.scrollToEnd(animated: true)
        }
        coordinator.update(nodes: nodesProvider(), atBottom: $atBottom)
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let columnID = NSUserInterfaceItemIdentifier("transcript")
        private static let cellID = NSUserInterfaceItemIdentifier("transcriptCell")
        private static let bubbleCellID = NSUserInterfaceItemIdentifier("bubbleCell")
        private static let log = Logger(subsystem: "com.tbd.app", category: "table-transcript")

        let context: TranscriptCardContext
        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?

        var nodes: [TranscriptRenderNode] = []
        var previousNodes: [TranscriptRenderNode] = []
        var lastScrollToken = 0

        /// Explicit per-row height cache, keyed by `(id, contentVersion, width)`.
        /// A re-poll that leaves a row's id+version unchanged reuses the cached
        /// height; a width change invalidates every entry (heights re-flow).
        private var heightCache: [HeightKey: CGFloat] = [:]
        /// The column width the cache was last computed against. When the table's
        /// width changes, the cache is cleared and the table reloaded.
        private var cachedColumnWidth: CGFloat = 0

        struct HeightKey: Hashable {
            let id: String
            let version: UInt64
            let width: CGFloat
        }

        /// A single reusable hosting controller used ONLY for height measurement.
        /// Reusing one controller (swapping its `rootView` per measure) instead of
        /// allocating a fresh `NSHostingController` for every row is ~3-4x cheaper,
        /// which is what keeps authoritative `heightOfRow` measurement off the
        /// freeze path on a long session. (#129)
        private let measuringController = NSHostingController(rootView: AnyView(EmptyView()))

        /// Composed `[MessageBlock]` for chat-bubble rows, keyed by
        /// `(node.id, contentVersion)`. The blocks `heightOfRow` measures are the
        /// SAME values `viewFor` installs into the cell, so render == measure by
        /// construction. Invalidated for a node on `updateLast` (growing stream)
        /// and cleared wholesale on a width-change reload.
        private var composedCache: [ComposedKey: [MessageBlock]] = [:]

        struct ComposedKey: Hashable {
            let id: String
            let version: UInt64
        }

        /// Reusable per-block measurer (TextKit-1 `usedRect` for prose, one-shot
        /// `sizeThatFits` for tables). Owned by the Coordinator so the
        /// storage/layout-manager allocation is paid once.
        private let blockMeasurer = MessageBlockMeasurer()

        init(context: TranscriptCardContext) {
            self.context = context
            super.init()
            measuringController.sizingOptions = [.preferredContentSize]
        }

        /// Returns (and caches) the composed blocks for a chat-bubble node:
        /// rendered markdown split at GFM tables, plus the token-usage badge when
        /// present.
        func composedBubbleBlocks(for node: TranscriptRenderNode, item: TranscriptItem) -> [MessageBlock] {
            let key = ComposedKey(id: node.id, version: node.contentVersion)
            if let cached = composedCache[key] { return cached }
            let composed = TranscriptBubbleGeometry.composedBlocks(for: item, badgeUsage: node.badgeUsage)
            composedCache[key] = composed
            return composed
        }

        /// FIX 1(b): eagerly measure and cache EVERY present row's exact height at
        /// the current column width, so the table's first `heightOfRow` walk (and
        /// every subsequent one until content changes) is a pure cache hit and no
        /// row is ever sized from an estimate. Cheap: bubble rows measure via the
        /// TextKit `usedRect` path (~0.04ms/row); hosted (SwiftUI) rows go through
        /// the reused measuring controller. Idempotent — already-cached rows are
        /// skipped — so calling it before each streaming insert only measures the
        /// newly-present rows.
        func precomputeAllHeights() {
            let width = columnWidth
            guard width > 1 else { return }
            for node in nodes {
                _ = measuredHeight(for: node, width: width)
            }
        }

        /// Test backstop: number of present rows whose exact height is already
        /// cached at the current column width. When this equals `nodes.count`
        /// after `precomputeAllHeights()`, every `tableView(_:heightOfRow:)` is a
        /// pure cache hit (no estimate, no on-realize re-measure) — the property
        /// FIX 1 depends on. (#129)
        var cachedHeightRowCount: Int {
            let width = columnWidth
            return nodes.reduce(into: 0) { count, node in
                let key = HeightKey(id: node.id, version: node.contentVersion, width: width)
                if heightCache[key] != nil { count += 1 }
            }
        }

        /// Authoritative natural content height of `node` at `width`, measured via
        /// the proven width-honouring `sizeThatFits` path over the `.fixedSize`
        /// row root, cached by `(id, contentVersion, width)`. A nil node (a row
        /// index AppKit asked for out of range) yields a small safe default.
        private func measuredHeight(for node: TranscriptRenderNode?, width: CGFloat) -> CGFloat {
            guard let node else { return 44 }
            let key = HeightKey(id: node.id, version: node.contentVersion, width: width)
            if let cached = heightCache[key] { return cached }

            let height: CGFloat
            if case .chatBubble(let item) = node.kind {
                // Chat bubbles: exact per-block height (TextKit-1 `usedRect` for
                // prose, one-shot `sizeThatFits` for tables) summed with
                // inter-block spacing, plus fixed chrome. This makes the row height
                // equal the cell's drawn block-stack height by construction.
                let role = TranscriptBubbleGeometry.role(for: item)
                let blocks = composedBubbleBlocks(for: node, item: item)
                let bodyWidth = TranscriptBubbleGeometry.bodyWidth(columnWidth: width, role: role)
                let blocksHeight = blockMeasurer.blocksHeight(blocks, bodyWidth: bodyWidth)
                height = TranscriptBubbleGeometry.rowHeight(blocksHeight: blocksHeight)
            } else {
                measuringController.rootView = AnyView(rowRootView(for: node))
                let proposed = NSSize(width: width, height: .greatestFiniteMagnitude)
                let measured = measuringController.sizeThatFits(in: proposed).height
                height = measured > 0 ? measured : 44
            }

            heightCache[key] = height
            return height
        }

        // MARK: Column width

        /// Content width available to a hosted row, derived from the table's
        /// current width. Mirrors the per-card inset used by the SwiftUI path so
        /// measured heights match what is rendered.
        private var columnWidth: CGFloat {
            guard let tableView else { return 0 }
            let raw = tableView.bounds.width
            return max(raw, 1)
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            nodes.count
        }

        // MARK: NSTableViewDelegate

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row >= 0, row < nodes.count else { return measuredHeight(for: nil, width: columnWidth) }
            // AUTHORITATIVE + PRECOMPUTED: this returns the row's exact natural
            // content height, which `precomputeAllHeights()` already measured and
            // cached for every present row at the current `(id, contentVersion,
            // width)`. So this is a pure cache-hit lookup — never an estimate and
            // never a provisional/placeholder value.
            //
            // This is deliberately NOT the estimate-then-`noteHeightOfRows`-correct
            // approach. That path returned a low estimate here and patched the real
            // height in after the row was realized — but the correction did not
            // reliably re-lay the row, and on Ventura+ AppKit ALSO estimated
            // off-screen rows from already-measured ones, so a row reserved too
            // much space and then visibly shrank as it scrolled in (the collapsing
            // blank gap). Disabling estimation (FIX 1a) + precomputing every height
            // (FIX 1b) makes this an exact cache hit and removes the jank.
            //
            // `measuredHeight` is retained as a defensive fallback only: if AppKit
            // ever asks for a row we somehow did not precompute, it measures it
            // once and caches it rather than returning a guess.
            return measuredHeight(for: nodes[row], width: columnWidth)
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard row >= 0, row < nodes.count else { return nil }
            let node = nodes[row]

            // Dual dispatch: chat bubbles render as exactly-measured attributed
            // text in a selectable NSTextView (render height == measure height by
            // construction); every other kind keeps the SwiftUI hosting path.
            if case .chatBubble(let item) = node.kind {
                return bubbleView(tableView, node: node, item: item)
            }

            let cell = dequeueOrMakeCell(tableView)
            // Lock the hosting view to the SAME box `heightOfRow` measured —
            // `columnWidth × measuredHeight` — so the SwiftUI content renders into
            // exactly the row's box. This is what makes render-height == row-height
            // by construction and removes the live clip/gap that an unconstrained
            // hosting-view width (wrapping at a different width than measurement)
            // produced.
            let width = columnWidth
            let reservedHeight = measuredHeight(for: node, width: width)
            cell.setContentBox(width: width, height: reservedHeight)
            cell.hostingView.rootView = AnyView(rowRootView(for: node))
            return cell
        }

        /// Dequeues (or makes) the dedicated attributed bubble cell and configures
        /// it from the SAME composed string `heightOfRow` measured, locked to the
        /// SAME `columnWidth × cachedHeight` box.
        private func bubbleView(
            _ tableView: NSTableView,
            node: TranscriptRenderNode,
            item: TranscriptItem
        ) -> NSView {
            let cell: TranscriptBubbleCellView
            if let reused = tableView.makeView(withIdentifier: Self.bubbleCellID, owner: self)
                as? TranscriptBubbleCellView {
                cell = reused
            } else {
                cell = TranscriptBubbleCellView()
                cell.identifier = Self.bubbleCellID
            }
            let width = columnWidth
            let role: TranscriptBubbleGeometry.Role = TranscriptBubbleGeometry.role(for: item)
            let blocks = composedBubbleBlocks(for: node, item: item)
            let height = measuredHeight(for: node, width: width)
            cell.configure(
                blocks: blocks,
                sourceText: TranscriptBubbleGeometry.text(for: item),
                role: role,
                header: TranscriptBubbleGeometry.header(for: item),
                bodyWidth: TranscriptBubbleGeometry.bodyWidth(columnWidth: width, role: role),
                columnWidth: width,
                cachedHeight: height
            )
            return cell
        }

        private func dequeueOrMakeCell(_ tableView: NSTableView) -> TranscriptHostingCellView {
            if let reused = tableView.makeView(withIdentifier: Self.cellID, owner: self)
                as? TranscriptHostingCellView {
                return reused
            }
            let cell = TranscriptHostingCellView()
            cell.identifier = Self.cellID
            return cell
        }

        /// Builds the SwiftUI root view for a node: the existing
        /// `SelectableTranscriptRow` with the transcript environment injected so
        /// card affordances (overlay open, thread drill, text selection) work
        /// exactly as in the SwiftUI pane.
        private func rowRootView(for node: TranscriptRenderNode) -> some View {
            SelectableTranscriptRow(node: node, terminalID: context.terminalID)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                // Measure AND render at the view's natural content height. Without
                // this, any row whose SwiftUI content has flexible vertical layout
                // reports a HUGE height when proposed an unbounded height
                // (`sizeThatFits` with `.greatestFiniteMagnitude`), producing the
                // ~600pt empty gaps. Pinning vertical to the content's natural
                // height makes the measured height equal the rendered height. (#129)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openTranscriptOverlay, context.openTranscriptOverlay)
                .environment(\.navigateToThread, context.navigateToThread)
                .environmentObjectIfPresent(context.appState)
        }

        // MARK: Estimate

        /// Cheap, LOW-biased height estimate from node kind + text length. No
        /// SwiftUI work — pure arithmetic so `heightOfRow` is O(1) before the real
        /// measurement lands. Biased low so rows grow (never shrink-then-jump)
        /// when the real height is patched in.
        nonisolated static func estimate(for node: TranscriptRenderNode?, width: CGFloat) -> CGFloat {
            guard let node else { return 32 }
            let charsPerLine = max(Int((width - 24) / 7.5), 20)
            let textLen: Int
            switch node.kind {
            case .chatBubble(let item):
                textLen = Self.chatBubbleEstimateLength(item)
            case .systemReminder(_, _, let text, _), .skillBody(_, let text, _):
                textLen = text.count
            case .toolCall(_, let name, let inputJSON, _, let result, _):
                textLen = name.count + min(inputJSON.count, 200) + min(result?.text.count ?? 0, 400)
            case .subagentSummary:
                return 40
            }
            let lines = max(1, (textLen + charsPerLine - 1) / charsPerLine)
            // ~18pt/line + chrome, biased a touch low.
            return CGFloat(lines) * 18 + 28
        }

        /// Text length of a chat-bubble item for the cheap height estimate.
        nonisolated static func chatBubbleEstimateLength(_ item: TranscriptItem) -> Int {
            switch item {
            case .userPrompt(_, let text, _),
                 .assistantText(_, let text, _, _),
                 .thinking(_, let text, _),
                 .systemReminder(_, _, let text, _):
                return text.count
            case .toolCall(_, let name, _, _, _, _, _, _):
                return name.count
            case .slashCommand(_, let name, let args, _):
                return name.count + (args?.count ?? 0)
            }
        }

        // MARK: Streaming update

        /// Apply a new poll result with a minimal table op derived from
        /// `TranscriptStreamPlan`. Captures at-bottom BEFORE the edit so a grown
        /// document doesn't misjudge whether to follow the tail.
        func update(nodes newNodes: [TranscriptRenderNode], atBottom: Binding<Bool>) {
            // `scrollView` must exist (downstream `scrollToEnd` / `isAtBottom`
            // read it via the stored property); bind it only to gate on presence.
            guard let tableView, scrollView != nil else { return }
            let step = TranscriptStreamPlan.step(previous: previousNodes, next: newNodes)

            // Width change: heights re-flow, so drop the cache, recompute every
            // height at the new width, then reload (a true rebuild, paired with a
            // full cache clear + recompute per FIX 1d).
            let width = columnWidth
            if abs(width - cachedColumnWidth) > 0.5 {
                cachedColumnWidth = width
                heightCache.removeAll(keepingCapacity: true)
                composedCache.removeAll(keepingCapacity: true)
                nodes = newNodes
                previousNodes = newNodes
                precomputeAllHeights()
                tableView.reloadData()
                recomputeAtBottom(atBottom)
                return
            }

            guard step != .noop else {
                previousNodes = newNodes
                nodes = newNodes
                return
            }

            let wasAtBottom = isAtBottom()
            let oldCount = nodes.count
            nodes = newNodes
            previousNodes = newNodes

            switch step {
            case .noop:
                break
            case .rebuild:
                // True rebuild: clear the cache, recompute every height, reload.
                heightCache.removeAll(keepingCapacity: true)
                composedCache.removeAll(keepingCapacity: true)
                precomputeAllHeights()
                tableView.reloadData()
            case let .append(fromIndex):
                let newCount = newNodes.count
                guard newCount > fromIndex, fromIndex <= oldCount else {
                    heightCache.removeAll(keepingCapacity: true)
                    composedCache.removeAll(keepingCapacity: true)
                    precomputeAllHeights()
                    tableView.reloadData()
                    break
                }
                // FIX 1(d): precompute the inserted rows' EXACT heights BEFORE the
                // insert, so the table never asks `heightOfRow` for an unmeasured
                // row (no estimate, no shrink-on-realize). `precomputeAllHeights`
                // is idempotent, so this only measures the new rows.
                precomputeAllHeights()
                let inserted = IndexSet(integersIn: fromIndex..<newCount)
                tableView.insertRows(at: inserted, withAnimation: [])
            case .updateLast:
                let last = newNodes.count - 1
                guard last >= 0 else { break }
                // Invalidate the last node's cached height across widths AND its
                // composed string (a growing streaming bubble must re-render and
                // re-measure), recompute its exact height, then ask the table to
                // re-fetch its cell and height.
                invalidateHeight(for: newNodes[last])
                invalidateComposed(for: newNodes[last])
                _ = measuredHeight(for: newNodes[last], width: columnWidth)
                if tableView.numberOfRows > last {
                    tableView.reloadData(
                        forRowIndexes: IndexSet(integer: last),
                        columnIndexes: IndexSet(integer: 0)
                    )
                    // FIX 1(c): this is a genuine post-hoc height change (the
                    // streamed last row grew), so `noteHeightOfRows` is legitimate
                    // here — but wrap it in a zero-duration NSAnimationContext so
                    // the row doesn't animate its height change.
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0
                        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: last))
                    }
                }
            }

            if wasAtBottom {
                DispatchQueue.main.async { [weak self] in
                    self?.scrollToEnd(animated: false)
                    self?.recomputeAtBottom(atBottom)
                }
            } else {
                recomputeAtBottom(atBottom)
            }
        }

        private func invalidateHeight(for node: TranscriptRenderNode) {
            for key in heightCache.keys where key.id == node.id {
                heightCache.removeValue(forKey: key)
            }
        }

        private func invalidateComposed(for node: TranscriptRenderNode) {
            for key in composedCache.keys where key.id == node.id {
                composedCache.removeValue(forKey: key)
            }
        }

        // MARK: Scrolling / at-bottom

        /// Whether the clip is within ~120pt of the document bottom (the
        /// follow-the-tail threshold shared with the TextKit path).
        private func isAtBottom() -> Bool {
            guard let scrollView, let documentView = scrollView.documentView else { return true }
            let clip = scrollView.contentView
            let visibleMaxY = clip.bounds.origin.y + clip.bounds.height
            let docMaxY = documentView.frame.height
            return TranscriptStreamPlan.isNearBottom(documentMaxY: docMaxY, visibleMaxY: visibleMaxY)
        }

        func scrollToEnd(animated: Bool) {
            guard let tableView, let scrollView else { return }
            let count = tableView.numberOfRows
            guard count > 0 else { return }
            tableView.scrollRowToVisible(count - 1)
            // Clamp the clip hard to the bottom: scrollRowToVisible can park a few
            // points short when the last row is tall.
            if let documentView = scrollView.documentView {
                let clip = scrollView.contentView
                let target = max(0, documentView.frame.height - clip.bounds.height)
                if target > clip.bounds.origin.y {
                    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
                    scrollView.reflectScrolledClipView(clip)
                }
            }
        }

        private func recomputeAtBottom(_ atBottom: Binding<Bool>) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                atBottom.wrappedValue = self.isAtBottom()
            }
        }
    }
}

// MARK: - Table view subclass

/// NSTableView subclass for the transcript pane.
///
/// FIX 2: NSTableView normally intercepts a cell subview's `mouseDown` and DELAYS
/// first responder by one click, so the first click on a chat bubble selects the
/// ROW instead of starting a text drag — selection (and Cmd-C copy) appears
/// broken. Overriding `validateProposedFirstResponder(_:for:)` to immediately
/// accept our `TranscriptBubbleTextView` lets the text view take the mouse on the
/// first click, so click-drag selection and copy work. `selectionHighlightStyle =
/// .none` does NOT bypass this gate, which is why selection failed before.
@MainActor
final class TranscriptBubbleTableView: NSTableView {
    override func validateProposedFirstResponder(
        _ responder: NSResponder,
        for event: NSEvent?
    ) -> Bool {
        // Let the selectable bubble text view become first responder immediately
        // (the click starts a text selection rather than a row selection).
        if responder is TranscriptBubbleTextView { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

// MARK: - Hosting cell

/// An `NSTableCellView` that hosts a SwiftUI row in an `NSHostingView<AnyView>`.
/// Reused by row identifier across the table's lifetime so scrolling virtualizes
/// the hosted views. (#129)
///
/// ## Why explicit width AND height constraints (not a top+bottom stretch)
/// The row's height is measured separately by `heightOfRow`
/// (`NSHostingController.sizeThatFits(width: columnWidth, height: ∞)`). For the
/// live pane to render WITHOUT clip or gap, the hosting view must lay the
/// SwiftUI content out into the EXACT same box that measurement assumed:
/// `columnWidth × measuredHeight`. The previous edge-pinned approach left the
/// hosting view's width unconstrained, so its SwiftUI layout could wrap at a
/// different effective width than the 680pt `sizeThatFits` used — producing a
/// render whose true height diverged from the row height (the live bottom-clip
/// of tall messages / token badges and the top-clip of the next header). Pinning
/// BOTH the width (= the measured width) and the height (= the measured height)
/// forces render-box == measure-box == row-box by construction. (#129)
@MainActor
final class TranscriptHostingCellView: NSTableCellView {
    let hostingView: NSHostingView<AnyView>
    private let widthConstraint: NSLayoutConstraint
    private let heightConstraint: NSLayoutConstraint

    override init(frame frameRect: NSRect) {
        hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        widthConstraint = hostingView.widthAnchor.constraint(equalToConstant: 1)
        heightConstraint = hostingView.heightAnchor.constraint(equalToConstant: 1)
        super.init(frame: frameRect)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            widthConstraint,
            heightConstraint
        ])
    }

    /// Locks the hosted SwiftUI row to the box the row height was measured for —
    /// `width × height` (the column width and the `sizeThatFits` height) — so the
    /// render and the row height cannot diverge.
    func setContentBox(width: CGFloat, height: CGFloat) {
        let w = max(width, 1)
        let h = max(height, 1)
        if abs(widthConstraint.constant - w) > 0.5 { widthConstraint.constant = w }
        if abs(heightConstraint.constant - h) > 0.5 { heightConstraint.constant = h }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Environment helper

private extension View {
    /// Injects the `AppState` environment object only when present, so the
    /// hosted row's `@EnvironmentObject var appState` resolves exactly as it does
    /// in the SwiftUI pane. A nil appState (headless harness without a wired
    /// state) leaves the row to render its appState-independent content.
    @ViewBuilder
    func environmentObjectIfPresent(_ appState: AppState?) -> some View {
        if let appState {
            self.environmentObject(appState)
        } else {
            self
        }
    }
}
