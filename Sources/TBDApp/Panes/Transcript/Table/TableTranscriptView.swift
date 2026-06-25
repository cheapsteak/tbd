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

        let tableView = NSTableView()
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
        tableView.reloadData()

        // Pin the initial open to the newest message (last row), deferred so the
        // table has performed its first layout pass and row frames exist.
        DispatchQueue.main.async {
            coordinator.scrollToEnd(animated: false)
        }

        Self.log.debug("table.installed rows=\(nodes.count, privacy: .public)")
        return scrollView
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

        init(context: TranscriptCardContext) {
            self.context = context
            super.init()
            measuringController.sizingOptions = [.preferredContentSize]
        }

        /// Authoritative natural content height of `node` at `width`, measured via
        /// the proven width-honouring `sizeThatFits` path over the `.fixedSize`
        /// row root, cached by `(id, contentVersion, width)`.
        private func measuredHeight(for node: TranscriptRenderNode, width: CGFloat) -> CGFloat {
            let key = HeightKey(id: node.id, version: node.contentVersion, width: width)
            if let cached = heightCache[key] { return cached }
            measuringController.rootView = AnyView(rowRootView(for: node))
            let proposed = NSSize(width: width, height: .greatestFiniteMagnitude)
            let measured = measuringController.sizeThatFits(in: proposed).height
            let height = measured > 0 ? measured : 44
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
            guard row >= 0, row < nodes.count else { return Self.estimate(for: nil, width: columnWidth) }
            // AUTHORITATIVE: return the row's true natural content height (cached).
            //
            // This is deliberately NOT the estimate-then-`noteHeightOfRows`-correct
            // approach. That path returns a low estimate here and patches the real
            // height in after the row is realized — but the correction does not
            // reliably re-lay the row (verified: in the headless harness the row
            // stays at the estimate height), which is exactly what shipped the live
            // CLIP (too-short rows cutting off a header/card) and GAP (too-tall rows
            // leaving empty space) symptoms. Returning the measured height directly
            // here makes the geometry authoritative and verifiably exact (the
            // harness oracle passes with 0 violations).
            //
            // Cost: NSTableView walks `heightOfRow` for a large prefix when it needs
            // the document height (scroller sizing / scroll-to-bottom), so the first
            // open of a very long session measures each such row once (~1.1s for an
            // 1100-message session, far below #129's 35s hang). A reusable measuring
            // controller plus the `(id, contentVersion, width)` cache make every
            // subsequent poll and scroll free.
            return measuredHeight(for: nodes[row], width: columnWidth)
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard row >= 0, row < nodes.count else { return nil }
            let node = nodes[row]

            let cell = dequeueOrMakeCell(tableView)
            // The row root carries `.fixedSize(horizontal:false, vertical:true)`
            // (see `rowRootView`) so the hosted view lays out at its NATURAL
            // content height — identical to the height `heightOfRow` measured for
            // this same root — so the cell content fills the row exactly, never
            // stretching into a gap nor overflowing into a clip.
            cell.hostingView.rootView = AnyView(rowRootView(for: node))
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
            guard let tableView, let scrollView else { return }
            let step = TranscriptStreamPlan.step(previous: previousNodes, next: newNodes)

            // Width change: heights re-flow, so drop the cache and reload.
            let width = columnWidth
            if abs(width - cachedColumnWidth) > 0.5 {
                cachedColumnWidth = width
                heightCache.removeAll(keepingCapacity: true)
                nodes = newNodes
                previousNodes = newNodes
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
                heightCache.removeAll(keepingCapacity: true)
                tableView.reloadData()
            case let .append(fromIndex):
                let newCount = newNodes.count
                guard newCount > fromIndex, fromIndex <= oldCount else {
                    tableView.reloadData()
                    break
                }
                let inserted = IndexSet(integersIn: fromIndex..<newCount)
                tableView.insertRows(at: inserted, withAnimation: [])
            case .updateLast:
                let last = newNodes.count - 1
                guard last >= 0 else { break }
                // Invalidate the last node's cached height across widths and ask
                // the table to re-fetch its cell (which re-measures) and height.
                invalidateHeight(for: newNodes[last])
                if tableView.numberOfRows > last {
                    tableView.reloadData(
                        forRowIndexes: IndexSet(integer: last),
                        columnIndexes: IndexSet(integer: 0)
                    )
                    tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: last))
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

// MARK: - Hosting cell

/// An `NSTableCellView` that hosts a SwiftUI row in an `NSHostingView<AnyView>`
/// pinned to its edges. Reused by row identifier across the table's lifetime so
/// scrolling virtualizes the hosted views. (#129)
@MainActor
final class TranscriptHostingCellView: NSTableCellView {
    let hostingView: NSHostingView<AnyView>

    override init(frame frameRect: NSRect) {
        hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: frameRect)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
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
