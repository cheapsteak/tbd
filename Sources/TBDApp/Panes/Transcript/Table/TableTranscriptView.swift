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
    /// Bumped by the pane whenever the USER toggles an activity group open or
    /// shut. The node array that arrives with a bumped token is the result of a
    /// disclosure gesture, not of streaming, so the coordinator anchors the
    /// clicked row instead of following the tail (see `update`).
    let activityToggleToken: Int
    let nodesProvider: @MainActor () -> [TranscriptRenderNode]

    private static let log = Logger(subsystem: "com.tbd.app", category: "table-transcript")

    func makeCoordinator() -> Coordinator {
        Coordinator(context: context)
    }

    func makeNSView(context ctx: Context) -> NSScrollView {
        // OPEN-PATH BOUNDARY TIMING (#129 freeze hunt). Permanent-but-off: emitted
        // at `.debug` so it is silent + free by default; re-enable with:
        //   log stream --level debug --predicate
        //     'subsystem == "com.tbd.app" AND category == "table-transcript"'
        let makeStart = DispatchTime.now().uptimeNanoseconds
        let coordinator = ctx.coordinator

        // Disable AppKit's off-screen row-height ESTIMATION. On Ventura+
        // NSTableView estimates the height of not-yet-realized rows from the rows
        // it has already measured (a single blended value); for a transcript whose
        // row heights vary wildly that guess is far off, so a row reserves the
        // wrong space and then visibly jumps when it scrolls into view. Turning it
        // off forces AppKit to ask OUR `heightOfRow` for every row — which returns
        // the cached EXACT height when present, else a GOOD per-kind estimate we
        // compute ourselves (much better than AppKit's single blended value). The
        // authoritative register happens at app launch
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
        coordinator.lastActivityToggleToken = activityToggleToken
        coordinator.atBottomBinding = $atBottom
        // Track the live scroll position so the jump-to-bottom button hides the
        // moment the viewport reaches the bottom — by the button OR a manual
        // scroll. Without this the flag only updated on node changes, so a
        // scroll-to-bottom left the button stuck on screen.
        coordinator.startObservingScroll()

        let nodes = nodesProvider()
        coordinator.nodes = nodes
        coordinator.previousNodes = nodes
        // LAZY MEASUREMENT (#129): eagerly measure + cache only the BOTTOM window
        // of rows (the open-at-bottom viewport + buffer) — a bounded, constant-time
        // cost regardless of session length. Older rows are sized by the cheap
        // per-kind estimate in `heightOfRow` until they scroll into view, where
        // `viewFor` measures them exactly and corrects. The instrumented variant
        // emits the `table.openperf` summary (now a SMALL precomputeMs) behind the
        // table-pane gate.
        coordinator.precomputeBottomWindowInstrumented()
        tableView.reloadData()

        // Pin the initial open to the newest message (last row), deferred so the
        // table has performed its first layout pass and row frames exist.
        DispatchQueue.main.async {
            coordinator.scrollToEnd(animated: false)
            // Re-pin once more on the NEXT runloop turn. The first scroll-to-end
            // lands on the bottom window's exact heights, but a row realizing just
            // above the viewport can still fire a zero-duration height correction
            // after this turn; with anchoring removed that correction no longer
            // compensates the offset, so a second `scrollToEnd` reasserts the
            // bottom after those corrections settle. (#129)
            DispatchQueue.main.async {
                coordinator.scrollToEnd(animated: false)
                // First layout has settled (bottom window measured, initial
                // scroll-to-end + its re-pin applied). One-shot boundary marker.
                let settledMs = Double(DispatchTime.now().uptimeNanoseconds &- makeStart) / 1_000_000
                Self.log.debug(
                    "table.open.firstLayoutSettled ms=\(settledMs, format: .fixed(precision: 1), privacy: .public)")
            }
        }

        // Create the syntax-highlighting JSCore VM OFF the main thread, ahead of
        // the first code cell. The open path (height precompute + first paint)
        // renders code blocks as plain monospaced text and never touches
        // JavaScriptCore — colors are applied asynchronously after display. (#129)
        CodeHighlightService.shared.warm()

        // One-time runtime verification of FIX 1(a): with the app-launch register
        // in place, `canEstimate` must read false by the time any table is set up.
        Self.log.info(
            "table.estimation canEstimate=\(UserDefaults.standard.bool(forKey: "NSTableViewCanEstimateRowHeights"), privacy: .public) usesAutomaticRowHeights=\(tableView.usesAutomaticRowHeights, privacy: .public)")

        Self.log.debug("table.installed rows=\(nodes.count, privacy: .public)")

        let makeNSViewMs = Double(DispatchTime.now().uptimeNanoseconds &- makeStart) / 1_000_000
        Self.log.debug(
            "table.open.makeNSViewDone ms=\(makeNSViewMs, format: .fixed(precision: 1), privacy: .public) rows=\(nodes.count, privacy: .public)")
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context ctx: Context) {
        let coordinator = ctx.coordinator
        if scrollToBottomToken != coordinator.lastScrollToken {
            coordinator.lastScrollToken = scrollToBottomToken
            coordinator.scrollToEnd(animated: true)
        }
        coordinator.update(
            nodes: nodesProvider(),
            atBottom: $atBottom,
            activityToggleToken: activityToggleToken
        )
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let columnID = NSUserInterfaceItemIdentifier("transcript")
        private static let cellID = NSUserInterfaceItemIdentifier("transcriptCell")
        private static let bubbleCellID = NSUserInterfaceItemIdentifier("bubbleCell")
        private static let activityCellID = NSUserInterfaceItemIdentifier("activityCell")
        private static let log = Logger(subsystem: "com.tbd.app", category: "table-transcript")

        let context: TranscriptCardContext
        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?

        var nodes: [TranscriptRenderNode] = []
        var previousNodes: [TranscriptRenderNode] = []
        var lastScrollToken = 0
        /// Last activity-group toggle token seen by `update`. A token that has
        /// MOVED means this node array came from the user opening or shutting a
        /// group, which must keep the clicked row where it is rather than
        /// re-pinning the tail.
        var lastActivityToggleToken = 0

        /// Live binding driving the floating jump-to-bottom button. Held so the
        /// clip-bounds observer can keep it in sync with the ACTUAL scroll
        /// position — not just on node updates. Refreshed every `update(...)`.
        var atBottomBinding: Binding<Bool>?

        /// Explicit per-row height cache, keyed by `(id, contentVersion, width)`.
        /// A re-poll that leaves a row's id+version unchanged reuses the cached
        /// height; a width change invalidates every entry (heights re-flow).
        private var heightCache: [HeightKey: CGFloat] = [:]
        /// Cheap per-kind ESTIMATE cache, keyed identically to `heightCache`.
        /// `heightOfRow` is called ~3×/row by AppKit and each compute scans the
        /// message text; caching the estimate turns those repeat scans into hash
        /// hits (~3× fewer `estimate(...)` computes per open). An entry here is
        /// SUPERSEDED by the exact height the moment a row is realized + measured
        /// in `viewFor` (the exact cache is consulted first). Both caches are
        /// cleared together on a width change and PRUNED (not cleared) to the live
        /// rows on a rebuild — see `pruneCaches`. (#129)
        private var estimateCache: [HeightKey: CGFloat] = [:]
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
        /// construction. Invalidated for a node on `updateLast` (growing stream),
        /// pruned to the live rows on a rebuild, and cleared wholesale on a
        /// width-change reload.
        private var composedCache: [ComposedKey: [MessageBlock]] = [:]

        struct ComposedKey: Hashable {
            let id: String
            let version: UInt64
        }

        /// Per-block measured heights for chat-bubble rows, keyed by
        /// `(node.id, contentVersion, width)`. Populated when `measuredHeight`
        /// sizes a bubble (it measures each block to sum the row height anyway, so
        /// it captures them here for free) and consumed by `bubbleView` so a
        /// scroll-reused `TranscriptBubbleCellView` lays its blocks out from the
        /// cache instead of re-measuring — notably avoiding a fresh
        /// `NSHostingController.sizeThatFits` for every `.table` block on every
        /// dequeue. Cleared alongside `heightCache`/`estimateCache` on a width
        /// change, pruned to the live rows on a rebuild, and dropped per-node on
        /// `updateLast`. (#129)
        private var blockHeightCache: [BlockHeightKey: [CGFloat]] = [:]

        struct BlockHeightKey: Hashable {
            let id: String
            let version: UInt64
            let width: CGFloat
        }

        /// Reusable per-block measurer (TextKit-1 `usedRect` for prose, one-shot
        /// `sizeThatFits` for tables). Owned by the Coordinator so the
        /// storage/layout-manager allocation is paid once.
        private let blockMeasurer = MessageBlockMeasurer()

        /// Open-path precompute instrumentation (#129 freeze hunt). Per-category
        /// elapsed time + counts accumulated inside `measuredHeight`, summarized
        /// in ONE `table.openperf` log line after `precomputeBottomWindow()`. All
        /// nanoseconds; converted to ms at log time. Reset at the start of each
        /// precompute so the figures describe that precompute pass alone.
        struct OpenPerf {
            var chatBubbleNanos: UInt64 = 0
            var chatBubbleRenderNanos: UInt64 = 0
            var chatBubbleMeasureNanos: UInt64 = 0
            var activityNanos: UInt64 = 0
            var askNanos: UInt64 = 0
            var chatBubbleCount = 0
            var activityCount = 0
            var askCount = 0
        }
        private var openPerf = OpenPerf()

        /// Counts `tableView(_:heightOfRow:)` calls. Read once shortly after open
        /// (one-shot dispatch) to learn whether AppKit asks for ALL rows' heights
        /// or only a visible subset — informing whether lazy measurement helps.
        private var heightOfRowCalls = 0

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

        /// Number of rows at the BOTTOM of the list to measure EXACTLY up front.
        /// The pane opens anchored to the newest message, so this covers the open
        /// viewport plus a scroll buffer; every other (older) row carries the cheap
        /// per-kind estimate from `heightOfRow` until it is realized (and then
        /// measured exactly + corrected in `viewFor`). Bounded so the open cost is
        /// constant regardless of session length. (#129)
        static let bottomEagerWindow = 40

        /// LAZY measurement: eagerly measure + cache the EXACT height of ONLY the
        /// bottom `bottomEagerWindow` rows — the open-at-bottom viewport plus a
        /// buffer — rather than every row. The remaining (older) rows are sized by
        /// the cheap per-kind ESTIMATE in `heightOfRow` until they scroll into view,
        /// at which point `viewFor` measures them exactly and corrects. This makes
        /// the open cost constant-time in session length (was O(rows): a 1612-node
        /// session spent ~3.9s measuring all 861 bubbles here). Idempotent — an
        /// already-cached row is a no-op — so the streaming append/update paths can
        /// call it to measure just their newly-present bottom rows. (#129)
        func precomputeBottomWindow() {
            let width = columnWidth
            guard width > 1 else { return }
            let start = max(0, nodes.count - Self.bottomEagerWindow)
            for index in start..<nodes.count {
                _ = measuredHeight(for: nodes[index], width: width)
            }
        }

        /// Open-path precompute + instrumentation (#129 freeze hunt). Resets the
        /// per-category accumulators, runs `precomputeBottomWindow()` measuring its
        /// wall-clock, then emits ONE `table.openperf` summary line: total node
        /// count, precompute ms (now the bounded BOTTOM-WINDOW cost only), and the
        /// per-category ms/count breakdown (chatBubble prose/table split into render
        /// vs measure, native activity, and the hosted askUserQuestion path). It
        /// also arms a one-shot dispatch to log how many `heightOfRow` calls AppKit
        /// made shortly after open.
        ///
        /// Called ONLY from the table pane's `makeNSView`. (#129)
        func precomputeBottomWindowInstrumented() {
            openPerf = OpenPerf()
            heightOfRowCalls = 0
            let start = DispatchTime.now().uptimeNanoseconds
            precomputeBottomWindow()
            let precomputeNanos = DispatchTime.now().uptimeNanoseconds &- start

            func ms(_ nanos: UInt64) -> Double { Double(nanos) / 1_000_000 }
            let p = openPerf
            // `.debug` so these perf summaries are silent + free by default. Read
            // them back with:
            //   log stream --level debug --predicate
            //     'subsystem == "com.tbd.app" AND category == "table-transcript"'
            Self.log.debug(
                """
                table.openperf nodeCount=\(self.nodes.count, privacy: .public) \
                precomputeMs=\(ms(precomputeNanos), format: .fixed(precision: 1), privacy: .public) \
                chatBubbleMs=\(ms(p.chatBubbleNanos), format: .fixed(precision: 1), privacy: .public) \
                chatBubbleCount=\(p.chatBubbleCount, privacy: .public) \
                markdownRenderMs=\(ms(p.chatBubbleRenderNanos), format: .fixed(precision: 1), privacy: .public) \
                textMeasureMs=\(ms(p.chatBubbleMeasureNanos), format: .fixed(precision: 1), privacy: .public) \
                activityMs=\(ms(p.activityNanos), format: .fixed(precision: 1), privacy: .public) \
                activityCount=\(p.activityCount, privacy: .public) \
                askUserQuestionMs=\(ms(p.askNanos), format: .fixed(precision: 1), privacy: .public) \
                askUserQuestionCount=\(p.askCount, privacy: .public)
                """
            )

            // One-shot: report how many heightOfRow calls landed during the first
            // run-loop turn after open (ALL rows ⇒ no lazy-measure win; a small
            // subset ⇒ lazy measurement could defer most of the precompute cost).
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                Self.log.debug(
                    "table.openperf.heightCalls heightOfRowCallsDuringOpen=\(self.heightOfRowCalls, privacy: .public) nodeCount=\(self.nodes.count, privacy: .public)")
            }
        }

        /// Test backstop: the cached per-block heights for `node` at the current
        /// column width, or nil if none are cached. Non-nil means a scroll-reused
        /// bubble cell will lay its blocks out from this cache rather than
        /// re-measuring (no `NSHostingController` re-alloc for a table block). (#129)
        func cachedBlockHeights(for node: TranscriptRenderNode) -> [CGFloat]? {
            blockHeightCache[BlockHeightKey(id: node.id, version: node.contentVersion, width: columnWidth)]
        }

        /// Test backstop: number of present rows whose EXACT height is already
        /// cached at the current column width. After `precomputeBottomWindow()`
        /// this is the bottom-window count (≤ `bottomEagerWindow`); the rest are
        /// sized by the per-kind estimate until realized. A realized row also
        /// becomes exact (measured + corrected in `viewFor`), so this grows as the
        /// user scrolls. (#129)
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
                //
                // Instrumented in two phases so we know whether the cost is
                // RENDERING (markdown → attributed string; fenced code is rendered
                // PLAIN here — syntax highlighting is async + off-main) or
                // MEASURING (TK1 `usedRect`). (#129)
                let branchStart = DispatchTime.now().uptimeNanoseconds
                let renderStart = DispatchTime.now().uptimeNanoseconds
                let blocks = composedBubbleBlocks(for: node, item: item)
                let renderEnd = DispatchTime.now().uptimeNanoseconds
                let bodyWidth = TranscriptBubbleGeometry.bodyWidth(
                    columnWidth: width, role: TranscriptBubbleGeometry.role(for: item))
                // Measure each block once and CACHE the per-block heights so the
                // realized cell reuses them (no NSHostingController re-alloc for a
                // table block on scroll). The row's body height is the SAME summed-
                // plus-spacing form, so render == measure by construction.
                let perBlock = blockMeasurer.blockHeights(blocks, bodyWidth: bodyWidth)
                blockHeightCache[BlockHeightKey(id: node.id, version: node.contentVersion, width: width)] = perBlock
                let blocksHeight = blockMeasurer.blocksHeight(fromBlockHeights: perBlock)
                let measureEnd = DispatchTime.now().uptimeNanoseconds
                height = TranscriptBubbleGeometry.rowHeight(blocksHeight: blocksHeight)
                openPerf.chatBubbleNanos &+= measureEnd &- branchStart
                openPerf.chatBubbleRenderNanos &+= renderEnd &- renderStart
                openPerf.chatBubbleMeasureNanos &+= measureEnd &- renderEnd
                openPerf.chatBubbleCount += 1
            } else if let presentation = ActivityRowFormatter.presentation(for: node) {
                // Native activity rows are ONE line by construction (the title is
                // truncated, never wrapped), so their height is a fixed chrome
                // height — no `sizeThatFits`, no SwiftUI work. This is what keeps
                // these rows off the per-row hosting precompute cost. (#129)
                let branchStart = DispatchTime.now().uptimeNanoseconds
                height = Self.activityRowHeight(style: presentation.style)
                openPerf.activityNanos &+= DispatchTime.now().uptimeNanoseconds &- branchStart
                openPerf.activityCount += 1
            } else {
                // Remaining hosted (SwiftUI) path — currently only AskUserQuestion.
                let branchStart = DispatchTime.now().uptimeNanoseconds
                measuringController.rootView = AnyView(rowRootView(for: node))
                let proposed = NSSize(width: width, height: .greatestFiniteMagnitude)
                let measured = measuringController.sizeThatFits(in: proposed).height
                height = measured > 0 ? measured : 44
                openPerf.askNanos &+= DispatchTime.now().uptimeNanoseconds &- branchStart
                openPerf.askCount += 1
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
            // Open-path instrumentation (#129): count how many heightOfRow calls
            // AppKit makes so we can tell whether it asks for every row up front
            // or only the visible window. Logged once via the one-shot dispatch.
            heightOfRowCalls += 1
            let width = columnWidth
            guard row >= 0, row < nodes.count else { return Self.estimate(for: nil, width: width) }
            let node = nodes[row]

            // LAZY MEASUREMENT (#129): if this row's EXACT height is already cached
            // (bottom-window precompute, or a previously-realized row), return it —
            // a pure cache hit. Otherwise return a GOOD cheap per-kind estimate (no
            // TextKit/SwiftUI layout). The row is then measured exactly when it is
            // realized in `viewFor`, which corrects the estimate via
            // `noteHeightOfRows`. The estimate is calibrated to sit a little UNDER
            // the measurement, so that correction GROWS the row — a row that grows
            // pushes not-yet-read content down off screen, while one that shrinks
            // pulls content up into the reading area as a visible jump. Returning
            // our OWN estimate — not relying on AppKit's single blended estimate
            // (which we disabled) — is what keeps a deep scroll-up landing close
            // before the correction.
            let key = HeightKey(id: node.id, version: node.contentVersion, width: width)
            if let cached = heightCache[key] { return cached }
            // Lazy estimate: serve a cached estimate if we already computed one for
            // this key, else compute it ONCE and cache. AppKit asks for a row's
            // height repeatedly (~3×) before realizing it; without this cache each
            // ask re-scans the message text. The exact cache above always wins, so
            // a realized row stops hitting the estimate path entirely. (#129)
            if let cachedEstimate = estimateCache[key] { return cachedEstimate }
            let estimate = Self.estimate(for: node, width: width)
            estimateCache[key] = estimate
            return estimate
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard row >= 0, row < nodes.count else { return nil }
            let node = nodes[row]

            // LAZY MEASUREMENT (#129): note whether this row's EXACT height was
            // already cached BEFORE we build the cell. If it was NOT (the row was
            // sized by the estimate in `heightOfRow`), the cell-building path below
            // measures and caches the exact height as a side effect; once the cell
            // is configured we compare the now-cached exact height to the estimate
            // AppKit used and, if they differ, ask AppKit to re-lay just this row.
            let width = columnWidth
            let wasExact = isExactHeightCached(node, width: width)
            let estimateUsed = wasExact ? 0 : Self.estimate(for: node, width: width)
            let cell = makeCell(tableView, node: node, row: row, width: width)
            if !wasExact {
                correctRowHeightIfNeeded(
                    tableView, row: row, node: node, width: width, estimate: estimateUsed)
            }
            return cell
        }

        /// Whether `node`'s exact height is already in the cache at `width` — i.e.
        /// `heightOfRow` returned an exact value (not the estimate) for this row.
        private func isExactHeightCached(_ node: TranscriptRenderNode, width: CGFloat) -> Bool {
            heightCache[HeightKey(id: node.id, version: node.contentVersion, width: width)] != nil
        }

        /// If the now-cached EXACT height differs from the `estimate` AppKit used
        /// for a freshly-realized (previously-estimated) row, ask AppKit to re-lay
        /// just this row, wrapped in a zero-duration animation so the height change
        /// is instant (no animated grow/shrink). Only on-screen rows reach here, so
        /// the correction is bounded to what the user can actually see. No
        /// scroll-offset compensation: the initial open pins to the bottom via
        /// `scrollToEnd`, and a realize-time correction must not drag the viewport
        /// away from there. (#129)
        private func correctRowHeightIfNeeded(
            _ tableView: NSTableView,
            row: Int,
            node: TranscriptRenderNode,
            width: CGFloat,
            estimate: CGFloat
        ) {
            let key = HeightKey(id: node.id, version: node.contentVersion, width: width)
            guard let exact = heightCache[key], abs(exact - estimate) > 0.5 else { return }
            guard tableView.numberOfRows > row else { return }

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            }
        }

        /// Builds the cell for `node`, measuring its exact height as a side effect
        /// (the per-kind cell configure all flow through `measuredHeight`, which
        /// caches). Dual/triple dispatch: chat bubbles → attributed bubble cell,
        /// native activity rows → `ActivityRowCellView`, AskUserQuestion → SwiftUI
        /// hosting cell.
        private func makeCell(
            _ tableView: NSTableView,
            node: TranscriptRenderNode,
            row: Int,
            width: CGFloat
        ) -> NSView? {
            // Chat bubbles render as exactly-measured attributed text in a
            // selectable NSTextView (render height == measure height by
            // construction); every other kind keeps the SwiftUI hosting path.
            if case .chatBubble(let item) = node.kind {
                return bubbleView(tableView, node: node, item: item)
            }

            // Native activity rows (tool headers, system reminders, skill bodies,
            // subagent summaries) render in ONE AppKit `ActivityRowCellView` — no
            // per-row `NSHostingController`. Only AskUserQuestion (a full
            // multi-bubble card) falls through to the SwiftUI hosting path below
            // (its presentation is nil).
            if let presentation = ActivityRowFormatter.presentation(for: node) {
                return activityView(tableView, node: node, presentation: presentation)
            }

            let cell = dequeueOrMakeCell(tableView)
            // Lock the hosting view to the SAME box `heightOfRow` measured —
            // `columnWidth × measuredHeight` — so the SwiftUI content renders into
            // exactly the row's box. This is what makes render-height == row-height
            // by construction and removes the live clip/gap that an unconstrained
            // hosting-view width (wrapping at a different width than measurement)
            // produced.
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
            // `measuredHeight` caches the row height AND (for a chat bubble) the
            // per-block heights as a side effect, so reading the block-height cache
            // afterward is a hit on the common scroll-reuse path — the cell then
            // never re-measures a table block. A miss (defensive) hands an empty
            // array; the cell re-measures per block.
            let height = measuredHeight(for: node, width: width)
            let blockHeights = blockHeightCache[
                BlockHeightKey(id: node.id, version: node.contentVersion, width: width)] ?? []
            cell.configure(
                blocks: blocks,
                blockHeights: blockHeights,
                sourceText: TranscriptBubbleGeometry.text(for: item),
                role: role,
                accessibilityAttribution: TranscriptBubbleGeometry.accessibilityAttribution(for: item),
                bodyWidth: TranscriptBubbleGeometry.bodyWidth(columnWidth: width, role: role),
                columnWidth: width,
                cachedHeight: height
            )
            return cell
        }

        /// Dequeues (or makes) the native activity cell and configures it from
        /// `presentation`, locked to `columnWidth × measuredHeight`. The click
        /// closure routes to the transcript overlay (most kinds) or the thread
        /// navigation (Agent/Task) per the presentation's target; a nil target
        /// (plain subagent summary) is a no-op.
        private func activityView(
            _ tableView: NSTableView,
            node: TranscriptRenderNode,
            presentation: ActivityRowPresentation
        ) -> NSView {
            let cell: ActivityRowCellView
            if let reused = tableView.makeView(withIdentifier: Self.activityCellID, owner: self)
                as? ActivityRowCellView {
                cell = reused
            } else {
                cell = ActivityRowCellView()
                cell.identifier = Self.activityCellID
            }
            let width = columnWidth
            let height = measuredHeight(for: node, width: width)
            let openOverlay = context.openTranscriptOverlay
            let onOpen: (() -> Void)?
            if case .activityGroupSummary(let summary) = node.kind {
                let toggleGroup = context.toggleActivityGroup
                onOpen = { toggleGroup?(summary.id, !summary.isExpanded) }
            } else {
                // The formatter only ever sets `openTargetID` (subagent drill-in
                // was removed); a nil target is a no-op.
                onOpen = presentation.openTargetID.map { target in
                    { openOverlay?(target) }
                }
            }
            cell.configure(
                presentation: presentation,
                columnWidth: width,
                height: height,
                onOpen: onOpen
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
                // The table pane is display-of-history with a single height
                // measurement per row, so its AskUserQuestion cards must render
                // statically (non-collapsible, fixed height) — otherwise a tap
                // collapses a historic card and breaks the cached row height.
                // The pending-question interaction lives in the live SwiftUI
                // pane, which leaves this env false. (#129)
                .environment(\.transcriptStaticCards, true)
                .environment(\.openTranscriptOverlay, context.openTranscriptOverlay)
                .environment(\.toggleTranscriptActivityGroup, context.toggleActivityGroup)
                .environmentObjectIfPresent(context.appState)
        }

        // MARK: Activity-row height

        /// Single-line subheadline height + vertical insets for a native activity
        /// row. Exact because the row is one truncated line: the title's tallest
        /// font is subheadline; the plain summary variant uses caption2. Vertical
        /// insets are the chrome's 4 (top) + 4 (bottom), and the row is at least
        /// as tall as the 14pt icon.
        private static let chromeRowHeight: CGFloat = {
            let font = NSFont.preferredFont(forTextStyle: .subheadline)
            let line = ceil(font.ascender - font.descender + font.leading)
            return ceil(max(line, 14) + 4 + 4)
        }()

        // The plain subagent-summary variant mirrors `SubagentSummaryRow`: a bare
        // caption2 HStack with NO vertical chrome padding, so its height is just
        // the caption2 line height (matching the SwiftUI oracle, ~13pt).
        private static let plainSummaryRowHeight: CGFloat = {
            let font = NSFont.preferredFont(forTextStyle: .caption2)
            return ceil(font.ascender - font.descender + font.leading)
        }()

        static func activityRowHeight(style: ActivityRowPresentation.RowStyle) -> CGFloat {
            switch style {
            case .chrome: return chromeRowHeight
            case .plainSummary: return plainSummaryRowHeight
            }
        }

        // MARK: Estimate

        /// Rendered height of one line fragment set in `font`, which is what the
        /// bubble's TextKit-1 `usedRect` reports per wrapped line. Derived from the
        /// font rather than frozen as a number: the theme's body font is
        /// `NSFont.preferredFont(forTextStyle: .body)`, so a host running a
        /// different system text size renders taller lines and a constant would be
        /// wrong there. `defaultLineHeight(for:)` is exactly the metric TextKit
        /// lays a fragment out at — measured against the production renderer it
        /// reproduces the true 16.0 pt body line for 13 pt SF to the point, which
        /// `ceil(ascender - descender + leading)` does not for every face (the
        /// monospaced code font rounds up from 15.31). (#129)
        private static func lineHeight(of font: NSFont) -> CGFloat {
            ceil(NSLayoutManager().defaultLineHeight(for: font))
        }

        /// Height of one wrapped prose line in a chat bubble (16.0 pt at 13 pt SF).
        private static let bubbleLineHeight: CGFloat =
            lineHeight(of: TranscriptTextTheme.chatBubble.bodyFont)
        /// Height of one line inside a fenced code block. `codeFont` is the
        /// monospaced face at the SAME point size as the body font, so this
        /// currently equals `bubbleLineHeight` — kept separate because that is a
        /// property of the theme, not a law.
        private static let codeLineHeight: CGFloat =
            lineHeight(of: TranscriptTextTheme.chatBubble.codeFont)
        /// Height of the trailing token-usage badge's own line. The badge is set in
        /// `NSFont.systemFont(ofSize: 9)` by `TranscriptBubbleGeometry.composedBlocks`.
        private static let badgeLineHeight: CGFloat = lineHeight(of: NSFont.systemFont(ofSize: 9))
        /// Line height of an ATX heading, indexed by `level - 1` (h1…h6). Headings
        /// are set in a scaled semibold system font, so they are materially taller
        /// than body prose (22 pt for h1 at 13 pt SF).
        private static let headingLineHeights: [CGFloat] = (1...6).map {
            lineHeight(of: TranscriptTextTheme.chatBubble.headingFont(level: $0))
        }
        /// Height of one GFM table grid row (header or body). MEASURED against the
        /// production `TranscriptTableView` at 2 and 4 columns and 2–7 grid rows: a
        /// non-wrapping row is 24.0 pt at every one of them. A row whose cell text
        /// wraps is taller (48 pt for two lines) and is deliberately not modelled —
        /// see `chatBubbleEstimate`.
        private static let tableRowHeight: CGFloat = 24

        /// Correction applied to the body font's raw mean character advance to turn
        /// it into the divisor `ceil(len / charsPerLine)` wants. MEASURED, not
        /// guessed: sweeping this factor against 1920 paragraph layouts (480
        /// generated paragraphs laid out at each of the four body widths the pane
        /// uses) and counting how often the arithmetic line count equals the
        /// laid-out one puts the peak on a broad plateau over 0.992…1.004, around
        /// 93% of paragraphs, falling away by more than ten points of exactness 4%
        /// to either side. The value is picked from INSIDE that plateau, at the end
        /// where the residual leans low: 106 paragraphs one line short against 38
        /// one line long, a mean of −0.035 lines per paragraph.
        ///
        /// Two ~1% effects sit underneath it and pull opposite ways — word wrap's
        /// ragged right edge fits ~1.2% fewer characters on a line than the pure
        /// advance says, while `ceil` rounds up ~1.2% more often than the true line
        /// count does. Both are small, which is why the plateau is broad; the old
        /// 7.0 pt/char constant was 14% off and had no plateau to sit on.
        ///
        /// `TranscriptEstimatorAccuracyTests.wrapArithmeticStaysCalibrated` is the
        /// standing guard: it re-runs the comparison (not the sweep) on every test
        /// run and fails if exactness falls off the plateau or the residual stops
        /// leaning low.
        private static let wrapCalibration: CGFloat = 0.994

        /// Representative English prose the mean character advance is taken from.
        /// Any long natural-language sample works; this one is fixed so the derived
        /// constant is reproducible.
        private static let advanceSample = """
            The table reserves space for an unrealized row with a cheap arithmetic \
            estimate, then corrects it to the measured height the moment the row is \
            realized, which means a biased estimate shows up to the reader as content \
            sliding under the cursor rather than as a wrong number anywhere.
            """

        /// Horizontal advance charged per prose character when approximating the
        /// wrapped line count — the theme body font's own mean advance over
        /// representative prose (6.138 pt at 13 pt SF), times `wrapCalibration`.
        /// Derived from the font for the same reason `bubbleLineHeight` is: a host
        /// at a different system text size wraps at a different character count,
        /// and the frozen 7.0 pt this replaces was 14% wrong even at the default
        /// size.
        ///
        /// `bodyWidth / this` is the number of characters that fit on a FULL
        /// (non-final) line, which is the quantity `ceil(len / charsPerLine)`
        /// wants: a paragraph of `len` characters fills ⌈len ÷ full-line capacity⌉
        /// lines. It yields 107 characters at the assistant body width of 656 pt,
        /// against a measured mean of 105.3 characters per laid-out full line.
        private static let bubbleCharAdvance: CGFloat = {
            meanAdvance(of: TranscriptTextTheme.chatBubble.bodyFont) * wrapCalibration
        }()

        /// What one character of an inline `code span` costs in body characters.
        /// The inline-code face is monospaced, so it is materially WIDER per
        /// character than the proportional body font (1.17× at the default size)
        /// — and this transcript's assistant prose is full of `file/paths` and
        /// `symbolNames()`. Ignoring it made a 200-character paragraph carrying one
        /// code span estimate two lines where it draws three.
        private static let inlineCodeCharWeight: CGFloat = {
            meanAdvance(of: TranscriptTextTheme.chatBubble.inlineCodeFont)
                / meanAdvance(of: TranscriptTextTheme.chatBubble.bodyFont)
        }()

        private static func meanAdvance(of font: NSFont) -> CGFloat {
            NSAttributedString(string: advanceSample, attributes: [.font: font]).size().width
                / CGFloat(advanceSample.count)
        }

        /// GOOD cheap per-kind height ESTIMATE — pure arithmetic, NO TextKit or
        /// SwiftUI layout — returned by `heightOfRow` for a row whose exact height
        /// is not yet cached, and corrected to the measured height when the row
        /// realizes. Calibrated to land within a few points of the measurement, and
        /// to leave what error remains on the LOW side so the correction GROWS the
        /// row: a row that grows as it realizes pushes not-yet-read content further
        /// down (off screen, unnoticed), while one that shrinks pulls content up
        /// into the reading area as a visible jump. (#129)
        ///
        /// * chatBubble: `chatBubbleEstimate` walks the message's source lines once
        ///   and sums what each will render as — wrapped prose lines, list items,
        ///   fenced code, GFM table grid rows, attached images — plus the paragraph
        ///   spacing between them and the bubble's fixed chrome.
        /// * activity rows (systemReminder / skillBody / non-Ask toolCall /
        ///   subagentSummary): the row is ONE truncated line, so its height is the
        ///   EXACT fixed chrome height (`activityRowHeight`) — cheap and exact, no
        ///   estimate error.
        /// * askUserQuestion (a hosted SwiftUI card): a calibrated constant; the
        ///   realized card measures exactly and corrects.
        static func estimate(for node: TranscriptRenderNode?, width: CGFloat) -> CGFloat {
            guard let node else { return 32 }
            switch node.kind {
            case .chatBubble(let item):
                return chatBubbleEstimate(item, badgeUsage: node.badgeUsage, columnWidth: width)
            case .systemReminder, .skillBody:
                return activityRowHeight(style: .chrome)
            case .activityGroupSummary:
                return activityRowHeight(style: .chrome)
            case .subagentSummary:
                return activityRowHeight(style: .plainSummary)
            case .toolCall(_, let name, _, _, _, _):
                // AskUserQuestion is the one toolCall that stays a hosted SwiftUI
                // card (its activity presentation is nil); every other toolCall is
                // a one-line chrome activity row.
                if name == "AskUserQuestion" { return Self.askUserQuestionEstimate }
                return activityRowHeight(style: .chrome)
            }
        }

        /// Calibrated constant for an unrealized AskUserQuestion card, corrected
        /// exactly when the card realizes.
        ///
        /// The card is a stack of chat bubbles — one per question, plus the answer
        /// bubble, with every option's label and description shown (the table pane
        /// renders these cards always-expanded and static). Its height is therefore
        /// driven by how that text WRAPS, not by anything countable from the raw
        /// JSON: measured against the production card, `1 question / 1 option` is
        /// 66 pt, `1 / 2` is 118, `1 / 4` is 144, `2 / 2×2` is 131, and a
        /// long-question / short-option card is 92 (680 pt column) or 105 (663) —
        /// two cards with identical question and option COUNTS differ by 26 pt.
        /// Scanning the JSON for `"question":` / `"label":` therefore buys nothing a
        /// constant does not, so this is the mean of the measured range, nudged
        /// down to keep the residual on the growing side for the common shapes.
        /// Spread against those six samples: −40 pt to +38 pt, against the old
        /// constant's +36 to +114 (it over-reserved on EVERY one of them).
        static let askUserQuestionEstimate: CGFloat = 104

        /// Arithmetic height estimate for a chat bubble. ONE pass over the message's
        /// source lines, no markdown parse and no text layout.
        ///
        /// The model mirrors what `MarkdownAttributedRenderer.renderBlocks` +
        /// `MessageBlockMeasurer` actually produce, which is what makes it accurate
        /// rather than merely cheap:
        ///
        /// * The message renders as an ordered list of BLOCKS — runs of prose, GFM
        ///   tables, attached images — separated by `interBlockSpacing`. Table and
        ///   image source lines are therefore counted ONCE, by their own term; the
        ///   prose loop skips them instead of also charging them as prose (charging
        ///   both put a four-row table 140 pt over).
        /// * Inside a prose block the renderer emits one paragraph per non-blank
        ///   source line and stamps each with a TRAILING spacing — `paragraphSpacing`
        ///   for ordinary text, the much tighter `listItemSpacing` for a list item —
        ///   which the LAST paragraph of the block does not pay. Blank source lines
        ///   render nothing at all: they are separators, not lines, so charging one
        ///   for each was 2 pt of over-estimate per paragraph break.
        /// * A fenced code block draws only its code lines; the ``` delimiters and
        ///   the language tag are not drawn. When such a block is followed by more
        ///   prose the visitor's trailing newline survives as one empty line
        ///   fragment, which is charged here in place of paragraph spacing.
        ///
        /// Three shapes are deliberately NOT modelled, all because they need real
        /// layout to see, and all three make this estimate SMALL — the safe
        /// direction, since an under-reservation grows on realize:
        ///
        /// * a GFM cell whose text wraps (that grid row is 48 pt, not 24) —
        ///   measured -48 pt on a four-times-wrapping cell;
        /// * a list item whose continuation lines wrap inside the 24 pt list
        ///   indent — measured exact out to 20 wrapped lines, so the indent has
        ///   yet to cost a whole line in practice;
        /// * a blockquote, whose `headIndent`/`firstLineHeadIndent` are also the
        ///   24 pt list indent, so it wraps narrower than the body width used here
        ///   while its `> ` markers are still counted as drawn characters —
        ///   measured exact to 12 wrapped lines and -16 pt (one line) at 20.
        ///
        /// The image term is not an approximation at all: an attached image is laid
        /// out at `TranscriptImageGeometry.displaySize`, which derives from a
        /// SYNCHRONOUS header-only probe (~0.1 ms, cached per file) rather than a
        /// decode — so the estimate can read the same true size the exact
        /// measurement will. Without it a screenshot row estimated ~1 line of prose
        /// for the marker text and then corrected by up to ~200pt on realize,
        /// dragging every row below it.
        private static func chatBubbleEstimate(
            _ item: TranscriptItem,
            badgeUsage: TokenUsage?,
            columnWidth: CGFloat
        ) -> CGFloat {
            let bodyWidth = TranscriptBubbleGeometry.bodyWidth(
                columnWidth: columnWidth, role: TranscriptBubbleGeometry.role(for: item))
            let charsPerLine = max(Int(bodyWidth / bubbleCharAdvance), 12)
            let text = TranscriptBubbleGeometry.text(for: item)

            // Split on image markers exactly as `renderBlocks` does, so the marker
            // text is not counted as prose and each image contributes its own block
            // height. Marker-free text (the overwhelmingly common case) costs one
            // substring search and yields a single text segment.
            var blocks = BlockAccumulator(charsPerLine: charsPerLine)
            for segment in TranscriptImageMarker.split(text) {
                switch segment {
                case .text(let run):
                    blocks.appendTextRun(run)
                case .image(let attachment):
                    blocks.appendBlock(
                        MessageBlockMeasurer.imageSize(attachment, bodyWidth: bodyWidth).height)
                }
            }
            blocks.flushProse()
            // The badge is appended to the LAST prose block (a new paragraph there,
            // so the paragraph before it starts paying its trailing spacing), or —
            // when the message has no prose at all — becomes a trailing prose block
            // of its own.
            if badgeUsage != nil { blocks.appendBadge() }

            return TranscriptBubbleGeometry.rowHeight(
                blocksHeight: max(blocks.totalHeight, bubbleLineHeight))
        }

        /// Accumulates the estimated block structure of one chat message: a
        /// sequence of prose / table / image blocks separated by
        /// `interBlockSpacing`, where a prose block is a sequence of paragraph
        /// units each of which pays a trailing spacing unless it is the block's
        /// last. Pure arithmetic over source lines.
        ///
        /// `@MainActor` because it reads the main-actor theme and the lazy
        /// font-derived constants above (a nested type does not inherit the
        /// enclosing class's isolation); it is only ever built inside
        /// `chatBubbleEstimate`, which is already on the main actor.
        @MainActor
        private struct BlockAccumulator {
            let charsPerLine: Int

            /// Summed heights of the blocks already closed.
            private var closedBlocksHeight: CGFloat = 0
            private var closedBlockCount = 0
            /// Whether any closed block is prose — the badge merges into the last
            /// such block rather than becoming a block of its own.
            private var hasProseBlock = false
            /// Height of the prose block currently being built, and the trailing
            /// spacing owed by its most recent unit (charged only if another unit
            /// follows).
            private var proseHeight: CGFloat = 0
            private var proseUnits = 0
            private var pendingTrailing: CGFloat = 0

            init(charsPerLine: Int) {
                self.charsPerLine = charsPerLine
            }

            /// Total body height: every block plus the spacing between them.
            var totalHeight: CGFloat {
                guard closedBlockCount > 0 else { return 0 }
                return closedBlocksHeight
                    + TranscriptBubbleGeometry.interBlockSpacing * CGFloat(closedBlockCount - 1)
            }

            /// Adds one already-sized block (image or table).
            mutating func appendBlock(_ height: CGFloat) {
                flushProse()
                closedBlocksHeight += height
                closedBlockCount += 1
            }

            /// Closes the prose block under construction, if any.
            mutating func flushProse() {
                guard proseUnits > 0 else { return }
                closedBlocksHeight += proseHeight
                closedBlockCount += 1
                hasProseBlock = true
                proseHeight = 0
                proseUnits = 0
                pendingTrailing = 0
            }

            /// One rendered paragraph: `lines` fragments of `lineHeight`, followed
            /// by `trailing` points of spacing IF another unit follows it in the
            /// same block.
            private mutating func appendUnit(lines: Int, lineHeight: CGFloat, trailing: CGFloat) {
                if proseUnits > 0 { proseHeight += pendingTrailing }
                proseHeight += CGFloat(max(lines, 1)) * lineHeight
                pendingTrailing = trailing
                proseUnits += 1
            }

            /// Wrapped line count of a source line at an effective wrap width of
            /// `charsPerLine / widthScale` characters.
            private func wrappedLines(_ line: String, widthScale: CGFloat = 1) -> Int {
                let capacity = max(Int(CGFloat(charsPerLine) / widthScale), 1)
                let length = Self.drawnLength(of: line)
                return max(1, (length + capacity - 1) / capacity)
            }

            /// Length of `line` measured in BODY characters — what it will cost on
            /// a wrapped line, rather than how many characters the markdown source
            /// spends saying it. Backticks are markup and are not drawn, and the
            /// characters between them are set in the wider monospaced inline-code
            /// face, so a code span costs more than its character count.
            ///
            /// Deliberately does NOT try to undo emphasis or link syntax: `**` and
            /// `*` are two-to-four characters against a whole line, and a link's
            /// hidden URL makes the line estimate LONG — which reserves more space,
            /// the safe direction. Code spans are singled out because they are both
            /// pervasive here and biased the UNSAFE way.
            private static func drawnLength(of line: String) -> Int {
                guard line.contains("`") else { return line.count }
                var total: CGFloat = 0
                var inCode = false
                for character in line {
                    if character == "`" {
                        inCode.toggle()
                        continue
                    }
                    total += inCode ? inlineCodeCharWeight : 1
                }
                return Int(total.rounded())
            }

            /// Appends the blocks a marker-free run of message text renders as.
            mutating func appendTextRun(_ run: String) {
                let theme = TranscriptTextTheme.chatBubble
                var inFence = false
                var fenceLines = 0
                var pendingTableRows = 0

                func flushTable() {
                    guard pendingTableRows > 0 else { return }
                    appendBlock(CGFloat(pendingTableRows) * tableRowHeight)
                    pendingTableRows = 0
                }

                for rawLine in run.split(omittingEmptySubsequences: false,
                                        whereSeparator: Self.isLineTerminator) {
                    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

                    if line.hasPrefix("```") || line.hasPrefix("~~~") {
                        if inFence {
                            // Closing delimiter: the block draws its code lines, and
                            // the visitor's surviving trailing newline shows up as
                            // one empty line fragment when more content follows.
                            inFence = false
                            appendUnit(lines: fenceLines, lineHeight: codeLineHeight,
                                       trailing: bubbleLineHeight)
                            fenceLines = 0
                        } else {
                            flushTable()
                            inFence = true
                            fenceLines = 0
                        }
                        continue
                    }
                    if inFence {
                        // Code never wraps into fewer lines than it has; long lines
                        // do wrap, but the tail indent makes that rare enough that
                        // one source line == one drawn line is the better model.
                        fenceLines += 1
                        continue
                    }

                    if line.isEmpty {
                        // A blank source line draws nothing — the separation it
                        // expresses is already paid by the previous unit's trailing
                        // spacing.
                        flushTable()
                        continue
                    }

                    if line.hasPrefix("|") {
                        // GFM grid row. The `|---|` separator draws as a border
                        // rather than a row, so it is not counted.
                        let cells = line.filter { $0 != "|" && $0 != "-" && $0 != ":" && $0 != " " }
                        if !cells.isEmpty { pendingTableRows += 1 }
                        continue
                    }
                    flushTable()

                    if let level = Self.headingLevel(of: line) {
                        // A heading's font is scaled, so it both draws taller and
                        // wraps at proportionally fewer characters.
                        let scale = theme.headingFont(level: level).pointSize / theme.bodyFont.pointSize
                        appendUnit(lines: wrappedLines(line, widthScale: scale),
                                   lineHeight: headingLineHeights[level - 1],
                                   trailing: theme.paragraphSpacing)
                        continue
                    }

                    appendUnit(
                        lines: wrappedLines(line),
                        lineHeight: bubbleLineHeight,
                        trailing: Self.isListItem(line) ? theme.listItemSpacing : theme.paragraphSpacing)
                }

                if inFence {
                    // Unterminated fence (a code block still streaming in): the
                    // renderer runs it to the end of the message, and being last it
                    // has no trailing spacing.
                    appendUnit(lines: fenceLines, lineHeight: codeLineHeight, trailing: 0)
                }
                flushTable()
            }

            /// Charges the trailing token-usage badge. It joins the last prose block
            /// as a new paragraph — so the paragraph before it starts paying its
            /// `paragraphSpacing` — or, with no prose to join, becomes its own block.
            mutating func appendBadge() {
                if hasProseBlock {
                    closedBlocksHeight += TranscriptTextTheme.chatBubble.paragraphSpacing + badgeLineHeight
                } else {
                    appendBlock(badgeLineHeight)
                }
            }

            /// The three line endings CommonMark recognises — and NOT the other
            /// things `Character.isNewline` reports, which cmark draws as ordinary
            /// characters.
            ///
            /// Splitting on the single `Character` `"\n"` is not enough, because
            /// `"\r\n"` is ONE extended grapheme cluster in Swift and therefore not
            /// equal to `"\n"`. A CRLF message contains no `"\n"` Character at all,
            /// so the old split handed back the entire message as a single line:
            /// no paragraphs, no list items, no fences, no table rows, one estimated
            /// line for the lot. Measured on a six-line CRLF message, that reserved
            /// 48 pt against a rendered 128.
            private static func isLineTerminator(_ character: Character) -> Bool {
                character == "\n" || character == "\r" || character == "\r\n"
            }

            /// ATX heading level (1…6) of `line`, or nil. `#hashtag` is not a
            /// heading — CommonMark requires whitespace (or end of line) after the
            /// hashes.
            private static func headingLevel(of line: String) -> Int? {
                var level = 0
                for character in line {
                    if character == "#" {
                        level += 1
                        if level > 6 { return nil }
                    } else {
                        return (level > 0 && character == " ") ? level : nil
                    }
                }
                return level > 0 ? level : nil
            }

            /// Whether `line` opens a bullet or ordered list item — the units the
            /// renderer spaces with the tight `listItemSpacing` instead of a full
            /// paragraph break.
            private static func isListItem(_ line: String) -> Bool {
                if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return true }
                var digits = 0
                for character in line {
                    if character.isNumber {
                        digits += 1
                        continue
                    }
                    guard digits > 0, character == "." || character == ")" else { return false }
                    let rest = line.dropFirst(digits + 1)
                    return rest.first == " "
                }
                return false
            }
        }

        // MARK: Streaming update

        /// Apply a new poll result with a minimal table op derived from
        /// `TranscriptStreamPlan`. Captures at-bottom BEFORE the edit so a grown
        /// document doesn't misjudge whether to follow the tail.
        ///
        /// `activityToggleToken` distinguishes the two reasons a node array can
        /// change shape. Streaming grows the transcript at the tail, and a viewer
        /// parked at the bottom expects to follow it. A disclosure toggle instead
        /// splices rows in (or out) UNDER the row the user just clicked, and there
        /// the only acceptable outcome is that the clicked row does not move: the
        /// toggle also classifies as a `.rebuild` (indices shift and the summary
        /// node's `contentVersion` folds in `isExpanded`), so without this signal
        /// the tail-follow below would re-pin the bottom and translate everything
        /// on screen upward by the height of the rows just revealed.
        func update(
            nodes newNodes: [TranscriptRenderNode],
            atBottom: Binding<Bool>,
            activityToggleToken: Int
        ) {
            // Keep the observer's binding fresh (SwiftUI hands us a new binding
            // each update).
            atBottomBinding = atBottom
            // Consume the toggle token unconditionally — BEFORE any early return —
            // so a toggle that lands on a `.noop` (or on a torn-down view) cannot
            // leave the signal armed and suppress the tail-follow of a later,
            // genuine streaming append.
            let isActivityToggle = activityToggleToken != lastActivityToggleToken
            lastActivityToggleToken = activityToggleToken
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
                estimateCache.removeAll(keepingCapacity: true)
                composedCache.removeAll(keepingCapacity: true)
                blockHeightCache.removeAll(keepingCapacity: true)
                nodes = newNodes
                previousNodes = newNodes
                precomputeBottomWindow()
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
                // True rebuild: the row ORDER changed, but every cache here is
                // content-addressed by `(id, contentVersion[, width])`, so a
                // surviving entry still describes the row it was measured for.
                // Prune to what the new list can reach, measure the bottom window
                // exactly, reload (older rows lazily estimate + correct on realize).
                pruneCaches(to: newNodes)
                precomputeBottomWindow()
                tableView.reloadData()
            case let .append(fromIndex):
                let newCount = newNodes.count
                guard newCount > fromIndex, fromIndex <= oldCount else {
                    pruneCaches(to: newNodes)
                    precomputeBottomWindow()
                    tableView.reloadData()
                    break
                }
                // Measure the newly-appended bottom rows EXACTLY before the insert,
                // so the streaming tail (which is on-screen) never displays from an
                // estimate. `precomputeBottomWindow` measures the bottom window —
                // which contains the just-appended rows — and is idempotent, so it
                // only measures rows not already cached.
                precomputeBottomWindow()
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

            // Follow the tail only for content the SESSION produced. A user-driven
            // disclosure toggle keeps the viewport exactly where it is, so the row
            // that was clicked stays under the pointer and only the content below
            // it moves. (Everything above the clicked row keeps its cached exact
            // height across the rebuild, so its rows do not re-lay either.)
            if wasAtBottom && !isActivityToggle {
                DispatchQueue.main.async { [weak self] in
                    self?.scrollToEnd(animated: false)
                    self?.recomputeAtBottom(atBottom)
                }
            } else {
                recomputeAtBottom(atBottom)
            }
        }

        /// Drops every cache entry that the new node list can no longer reach,
        /// keeping the rest.
        ///
        /// Every cache here is keyed by `(id, contentVersion[, width])`, so a
        /// stale entry — one whose row changed content, or which is gone from the
        /// list — is unreachable by construction: a lookup for the row's NEW
        /// version simply misses. Clearing them on a rebuild was therefore pure
        /// pessimism with a real cost: a row measured EXACTLY fell back to the
        /// arithmetic estimate, got re-measured on realize, and was corrected via
        /// `noteHeightOfRows` with no scroll compensation — so a visible row above
        /// the user's focus that corrected by δ dragged everything below it by δ.
        ///
        /// Keeping them needs a growth story, which is what this prune is: after
        /// it, the caches hold at most one entry per LIVE row per cache (plus
        /// whatever the width-change path already clears wholesale). Between
        /// prunes only live rows are ever measured — `.append` adds entries for
        /// the rows it appended, and `.updateLast` invalidates the grown row's
        /// entries by id before re-measuring — so a long streaming session cannot
        /// accumulate one entry per superseded `contentVersion`.
        private func pruneCaches(to newNodes: [TranscriptRenderNode]) {
            var live = Set<ComposedKey>(minimumCapacity: newNodes.count)
            for node in newNodes {
                live.insert(ComposedKey(id: node.id, version: node.contentVersion))
            }
            heightCache = heightCache.filter { live.contains(ComposedKey(id: $0.key.id, version: $0.key.version)) }
            estimateCache = estimateCache.filter { live.contains(ComposedKey(id: $0.key.id, version: $0.key.version)) }
            composedCache = composedCache.filter { live.contains($0.key) }
            blockHeightCache = blockHeightCache.filter {
                live.contains(ComposedKey(id: $0.key.id, version: $0.key.version))
            }
        }

        /// Test backstop: total entries held across every per-row cache. Bounds the
        /// growth story in `pruneCaches` — after a rebuild this cannot exceed a
        /// small multiple of the live row count.
        var totalCachedEntryCount: Int {
            heightCache.count + estimateCache.count + composedCache.count + blockHeightCache.count
        }

        /// Test backstop: the cached EXACT height for `node` at the current column
        /// width, or nil when the row would be sized by the estimate instead.
        func cachedExactHeight(for node: TranscriptRenderNode) -> CGFloat? {
            heightCache[HeightKey(id: node.id, version: node.contentVersion, width: columnWidth)]
        }

        private func invalidateHeight(for node: TranscriptRenderNode) {
            for key in heightCache.keys where key.id == node.id {
                heightCache.removeValue(forKey: key)
            }
            // Drop any cached estimate for this node too, so a growing streaming
            // bubble re-estimates (and re-measures) at its new content rather than
            // serving the stale estimate the first poll cached. (#129)
            for key in estimateCache.keys where key.id == node.id {
                estimateCache.removeValue(forKey: key)
            }
            // Drop this node's cached per-block heights — they'll be re-measured
            // (and re-cached) when the grown bubble is re-sized.
            for key in blockHeightCache.keys where key.id == node.id {
                blockHeightCache.removeValue(forKey: key)
            }
        }

        private func invalidateComposed(for node: TranscriptRenderNode) {
            for key in composedCache.keys where key.id == node.id {
                composedCache.removeValue(forKey: key)
            }
        }

        // MARK: Scrolling / at-bottom

        /// Subscribe to clip-bounds changes so `atBottom` reflects the LIVE scroll
        /// position. AppKit posts this on the main thread during every scroll
        /// (button-driven or manual), so the jump-to-bottom button hides as soon
        /// as the viewport reaches the bottom and reappears when the user scrolls
        /// away — instead of only re-evaluating on a node update.
        func startObservingScroll() {
            guard let clip = scrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipBoundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: clip
            )
        }

        @objc private func clipBoundsDidChange() {
            guard let binding = atBottomBinding else { return }
            let value = isViewportAtBottomForButton()
            // Only write on a transition so a scroll gesture flips the flag at
            // most twice (entering/leaving the bottom), not once per frame.
            if binding.wrappedValue != value {
                binding.wrappedValue = value
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        /// Vertical gap between the viewport's bottom edge and the document
        /// bottom, in points (≤0 when the last content is flush with or above the
        /// viewport bottom).
        private func viewportGapToBottom() -> CGFloat {
            guard let scrollView, let documentView = scrollView.documentView else { return 0 }
            let clip = scrollView.contentView
            let visibleMaxY = clip.bounds.origin.y + clip.bounds.height
            return documentView.frame.height - visibleMaxY
        }

        /// Whether the clip is within ~120pt of the document bottom — the tight
        /// FOLLOW-THE-TAIL threshold (shared with the TextKit path). Kept small so
        /// a modest upward scroll stops new streamed content from yanking the
        /// viewport back down.
        private func isAtBottom() -> Bool {
            guard scrollView?.documentView != nil else { return true }
            return TranscriptStreamPlan.isNearBottom(
                documentMaxY: viewportGapToBottom(), visibleMaxY: 0)
        }

        /// Whether the viewport is close enough to the bottom to HIDE the floating
        /// jump-to-bottom button. Deliberately looser than `isAtBottom()`: the
        /// button only appears once you're a meaningful distance away — at least
        /// 400pt or half a viewport, whichever is larger. This keeps it from
        /// lingering after a near-bottom landing (a small residual gap from
        /// lazy-height realization no longer pins it open) and from flickering
        /// near the bottom, while leaving stream auto-scroll on the tight
        /// threshold above.
        private func isViewportAtBottomForButton() -> Bool {
            guard let scrollView, scrollView.documentView != nil else { return true }
            let viewportHeight = scrollView.contentView.bounds.height
            let threshold = max(400, viewportHeight * 0.5)
            return viewportGapToBottom() <= threshold
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
                atBottom.wrappedValue = self.isViewportAtBottomForButton()
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
