import AppKit
import SwiftUI
import TBDShared
import os

// THROWAWAY SPIKE (issue #129). Goal: prove an AppKit virtualizing list can
// replace the transcript's `LazyVStack { ForEach }` so only ~visible rows are
// realized/reconciled per content change (O(visible)) instead of SwiftUI's
// `ForEach.applyNodes` reconciling ALL N rows (O(N)).
//
// List class chosen: view-based NSTableView with usesAutomaticRowHeights.
// Rationale: variable, self-sizing row heights are NSTableView's documented
// happy path (`usesAutomaticRowHeights = true` lets each row's NSHostingView
// autolayout-fit), and NSTableView only realizes visible rows + a small
// overscan. NSCollectionView would require a compositional list layout with
// estimated heights to self-size variable content — strictly more risk for no
// extra payoff here. We disable the table's own selection so plain CLICKS reach
// the hosted SwiftUI controls (tool-row overlay buttons, file-link buttons,
// AskUserQuestion buttons) instead of being swallowed for row selection:
// selectionHighlightStyle = .none and rows are non-selectable for AppKit's
// purposes. (In-row text selection is intentionally dropped — see RowHost.)

/// `NSViewRepresentable` wrapping an `NSScrollView`+`NSTableView` that hosts one
/// `TranscriptRow` per `TranscriptRenderNode`. Behind `TBD_VIRT_TRANSCRIPT=1`.
@MainActor
struct VirtualizedTranscriptList: NSViewRepresentable {
    let nodes: [TranscriptRenderNode]
    let terminalID: UUID?

    func makeCoordinator() -> Coordinator {
        Coordinator(terminalID: terminalID)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let tableView = TranscriptTableView()
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.usesAutomaticRowHeights = true
        tableView.rowSizeStyle = .custom
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        // Disable the table's own selection so a click inside a row reaches the
        // hosted SwiftUI controls (tool-row overlay buttons, file-link buttons,
        // AskUserQuestion buttons) instead of being claimed for row selection.
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.gridStyleMask = []

        let column = NSTableColumn(identifier: .init("transcript"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        // Single full-width column: the table column must track the table's
        // width so each row's NSHostingView gets a real width to autolayout
        // against (usesAutomaticRowHeights derives row height from that width).
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        coordinator.tableView = tableView
        coordinator.nodes = nodes

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = tableView
        scrollView.automaticallyAdjustsContentInsets = false
        // The table is the documentView; make it track the scrollView's width so
        // it always has a non-zero frame to lay rows out in. Without this the
        // table can be measured at zero width, automatic row heights collapse,
        // and rows never become visible → blank.
        tableView.autoresizingMask = [.width, .height]

        // Initial load pins to bottom (newest content visible), matching the
        // production transcript which starts scrolled to the latest item.
        // Note: makeNSView often runs with empty `nodes` (the harness/data
        // arrives via updateNSView → scheduleUpdate), so this reload may be a
        // no-op; the deferred apply then populates + re-pins to bottom.
        tableView.reloadData()
        DispatchQueue.main.async {
            coordinator.scrollToBottomIfNeeded(force: true)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.terminalID = terminalID
        // CRITICAL: do NOT mutate the NSTableView synchronously here. This runs
        // inside SwiftUI's update/layout pass; calling reloadData/insertRows now
        // re-enters AppKit's table-view layout reentrantly. AppKit detects the
        // reentrancy ("Application performed a reentrant operation in its
        // NSTableView delegate"), the warning fires, and the reload is dropped —
        // numberOfRows/viewFor never realize → blank render. Defer the apply to
        // the next main-runloop turn so it runs OUTSIDE the SwiftUI pass. Coalesce
        // rapid updates: stash the latest nodes and only apply once per turn.
        coordinator.scheduleUpdate(to: nodes)
    }

    /// Owns the data array, the table, and bottom-pin state. Acts as both
    /// dataSource and delegate.
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var nodes: [TranscriptRenderNode] = []
        var terminalID: UUID?
        weak var tableView: NSTableView?

        /// Latest nodes awaiting a deferred apply. A non-nil value means a
        /// main-runloop apply is already scheduled; we just overwrite the payload
        /// so only the newest array is applied (coalescing rapid updates).
        private var pendingNodes: [TranscriptRenderNode]?

        /// Above this many appended rows in one update we fall back to
        /// `reloadData()` instead of `insertRows`. Bulk `insertRows` of
        /// automatic-height rows is heavy/fragile; the initial empty→N
        /// population (potentially hundreds of rows) should reload once.
        nonisolated private static let maxIncrementalInsert = 32

        nonisolated private static let perfLog = Logger(subsystem: "com.tbd.app", category: "perf-transcript")
        nonisolated private static let realizeLoggingEnabled =
            ProcessInfo.processInfo.environment["TBD_PERF_ROW_REALIZE"] == "1"

        init(terminalID: UUID?) {
            self.terminalID = terminalID
        }

        // MARK: Data update

        /// Coalesce + defer the table mutation out of SwiftUI's update pass.
        /// Stores the latest nodes; if no apply is yet scheduled, schedules one
        /// for the next main-runloop turn. Repeated calls within the same turn
        /// just replace the payload so we apply only the newest array once.
        func scheduleUpdate(to newNodes: [TranscriptRenderNode]) {
            let alreadyScheduled = pendingNodes != nil
            pendingNodes = newNodes
            guard alreadyScheduled == false else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let latest = self.pendingNodes else { return }
                self.pendingNodes = nil
                self.update(to: latest)
            }
        }

        /// Diff the incoming node array against the current one and apply the
        /// minimal table mutation. The common streaming case is a pure append
        /// (same prefix, new suffix) → `insertRows`, which keeps existing rows'
        /// hosting views alive and only realizes the newly visible tail.
        /// Anything else falls back to `reloadData()` (still O(visible) to
        /// realize). After either path, re-pin to the bottom if we were near it.
        func update(to newNodes: [TranscriptRenderNode]) {
            guard let tableView else {
                nodes = newNodes
                return
            }
            let wasNearBottom = isNearBottom()
            let old = nodes

            let appendCount = newNodes.count - old.count
            if appendCount > 0,
               appendCount <= Self.maxIncrementalInsert,
               Array(newNodes.prefix(old.count)) == old {
                // Small streaming append on top of an existing array: insert just
                // the new tail so existing rows' hosting views stay alive and only
                // the newly visible rows realize. Reserve insertRows for genuine
                // small appends — bulk-inserting hundreds of automatic-height rows
                // is heavy/fragile, so the large initial population (empty → N)
                // takes the reloadData path below instead.
                let insertedRange = old.count ..< newNodes.count
                nodes = newNodes
                tableView.insertRows(
                    at: IndexSet(integersIn: insertedRange),
                    withAnimation: []
                )
            } else if newNodes != old {
                nodes = newNodes
                tableView.reloadData()
            } else {
                return // no change
            }

            if wasNearBottom {
                DispatchQueue.main.async { [weak self] in
                    self?.scrollToBottomIfNeeded(force: true)
                }
            }
        }

        // MARK: Bottom-pin

        /// True when the scroll position is at/near the bottom (within one
        /// viewport-height fudge), so streaming appends auto-scroll while a
        /// user who has scrolled up is left alone.
        func isNearBottom() -> Bool {
            guard let tableView, let scrollView = tableView.enclosingScrollView else { return true }
            let visible = scrollView.contentView.bounds
            let documentHeight = tableView.bounds.height
            let viewportBottom = visible.origin.y + visible.height
            // 40pt threshold mirrors the production at-bottom sentinel intent.
            return documentHeight - viewportBottom < 40
        }

        func scrollToBottomIfNeeded(force: Bool) {
            guard let tableView, nodes.isEmpty == false else { return }
            if force || isNearBottom() {
                tableView.scrollRowToVisible(nodes.count - 1)
            }
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            nodes.count
        }

        // MARK: NSTableViewDelegate

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard row >= 0, row < nodes.count else { return nil }
            let node = nodes[row]

            if Self.realizeLoggingEnabled {
                Self.perfLog.debug("virt.realize id=\(node.id, privacy: .public) row=\(row, privacy: .public)")
            }

            // Reuse a recycled host cell if the table offers one; otherwise make
            // a fresh one. This is the virtualization seam — AppKit only calls
            // this for rows entering the visible region (plus a small overscan).
            let identifier = NSUserInterfaceItemIdentifier("transcript-cell")
            let cell: HostingTableCellView
            if let recycled = tableView.makeView(withIdentifier: identifier, owner: self) as? HostingTableCellView {
                cell = recycled
            } else {
                cell = HostingTableCellView()
                cell.identifier = identifier
            }
            cell.configure(node: node, terminalID: terminalID)
            return cell
        }

        // No row selection: returning false keeps AppKit from claiming the
        // click for row selection so it reaches the hosted SwiftUI controls.
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            false
        }
    }
}

/// NSTableView subclass that yields hit-testing to its hosted SwiftUI content.
/// Default NSTableView mouse handling can begin a row-tracking drag; by not
/// implementing row selection (delegate returns false) and letting the cell's
/// NSHostingView be the first responder for clicks, a click inside a row reaches
/// the hosted SwiftUI controls (tool-row overlay buttons, file-link buttons,
/// AskUserQuestion buttons) instead of selecting the row.
private final class TranscriptTableView: NSTableView {
    // Allow clicks inside a row to reach the hosted SwiftUI controls (buttons,
    // links) instead of being swallowed for row selection / first-responder
    // tracking. This is about delivering plain CLICKS to hosted controls — NOT
    // text selection, which the virtualized path intentionally drops (#129).
    //
    // NSTableView normally rejects hosted subviews as the proposed first
    // responder and claims the click for itself (row selection tracking).
    // Returning true here lets AppKit deliver the event to the deepest hit
    // view — the NSHostingView's hosted control — through its OWN, normal
    // event routing. We do NOT manually forward events (no `mouseDown` +
    // `hitTest().mouseDown(event)`); that created mutual recursion between the
    // table and the hosting view's responder-chain forwarding and overflowed
    // the stack (#129 live-test crash).
    override func validateProposedFirstResponder(
        _ responder: NSResponder,
        for event: NSEvent?
    ) -> Bool {
        true
    }
}

/// `NSTableCellView` hosting one `TranscriptRow` via `NSHostingView`.
private final class HostingTableCellView: NSTableCellView {
    private var hostingView: NSHostingView<RowHost>?

    func configure(node: TranscriptRenderNode, terminalID: UUID?) {
        let root = RowHost(node: node, terminalID: terminalID)
        if let hostingView {
            hostingView.rootView = root
        } else {
            let host = NSHostingView(rootView: root)
            host.translatesAutoresizingMaskIntoConstraints = false
            // sizingOptions so the host self-sizes to its SwiftUI content,
            // which usesAutomaticRowHeights reads for the row height.
            host.sizingOptions = [.intrinsicContentSize]
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.topAnchor.constraint(equalTo: topAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            hostingView = host
        }
    }
}

/// SwiftUI wrapper hosting one `TranscriptRow`.
///
/// In-row text selection is intentionally DROPPED for the virtualized path
/// (#129 spike decision): not freezing matters more than in-row selection, and
/// the AppKit `NSTableView`-vs-hosted-text drag conflict made in-row selection
/// unworkable without a crashing event hack (the `mouseDown` forwarding that
/// caused the SIGSEGV recursion). `\.transcriptTextSelection` defaults to
/// false, so no `.textSelection(.enabled)`/NSTextField materializes (no
/// drag-select) and the per-row hover churn is gone too.
private struct RowHost: View {
    let node: TranscriptRenderNode
    let terminalID: UUID?

    var body: some View {
        TranscriptRow(node: node, terminalID: terminalID)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
