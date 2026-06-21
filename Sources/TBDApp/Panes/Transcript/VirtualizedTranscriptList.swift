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
// extra payoff here. We disable the table's own selection so mouse drags reach
// the hosted SwiftUI text (#244 text selection): selectionHighlightStyle =
// .none and rows are non-selectable for AppKit's purposes.

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
        // Disable the table's own selection so a mouse drag inside a row
        // selects TEXT (reaching the hosted SwiftUI `.textSelection`), not the
        // row. This is THE #244 gating risk.
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.gridStyleMask = []

        let column = NSTableColumn(identifier: .init("transcript"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

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

        // Initial load pins to bottom (newest content visible), matching the
        // production transcript which starts scrolled to the latest item.
        tableView.reloadData()
        DispatchQueue.main.async {
            coordinator.scrollToBottomIfNeeded(force: true)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.terminalID = terminalID
        coordinator.update(to: nodes)
    }

    /// Owns the data array, the table, and bottom-pin state. Acts as both
    /// dataSource and delegate.
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var nodes: [TranscriptRenderNode] = []
        var terminalID: UUID?
        weak var tableView: NSTableView?

        nonisolated private static let perfLog = Logger(subsystem: "com.tbd.app", category: "perf-transcript")
        nonisolated private static let realizeLoggingEnabled =
            ProcessInfo.processInfo.environment["TBD_PERF_ROW_REALIZE"] == "1"

        init(terminalID: UUID?) {
            self.terminalID = terminalID
        }

        // MARK: Data update

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

            if newNodes.count > old.count, Array(newNodes.prefix(old.count)) == old {
                // Pure append. Insert just the new tail.
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
        // click/drag for row selection so it reaches the hosted text.
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            false
        }
    }
}

/// NSTableView subclass that yields hit-testing to its hosted SwiftUI content.
/// Default NSTableView mouse handling can begin a row-tracking drag; by not
/// implementing row selection (delegate returns false) and letting the cell's
/// NSHostingView be the first responder for clicks, drags inside a row reach
/// the SwiftUI `.textSelection(.enabled)` text instead of selecting the row.
private final class TranscriptTableView: NSTableView {
    // Let the hosted SwiftUI view handle mouse-down/drag for text selection.
    // We deliberately do NOT call super for in-row drags; AppKit's default
    // `mouseDown` starts row selection tracking which would swallow the drag.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0 {
            // Forward to the hosting view so SwiftUI text selection sees the
            // drag. hitTest finds the deepest NSView (the NSHostingView's
            // internal text view) under the cursor.
            if let target = hitTest(convert(event.locationInWindow, from: nil)) {
                target.mouseDown(with: event)
                return
            }
        }
        super.mouseDown(with: event)
    }
}

/// `NSTableCellView` hosting one `TranscriptRow` via `NSHostingView`. Owns the
/// per-row hover gate so `.textSelection(.enabled)` materializes on hover
/// exactly like production's `SelectableTranscriptRow`.
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

/// SwiftUI wrapper that mirrors `SelectableTranscriptRow`: owns per-row hover
/// state and flips `\.transcriptTextSelection` true on hover so
/// `.textSelection(.enabled)` is materialized only for the hovered row — the
/// same #120-preserving behavior as production.
private struct RowHost: View {
    let node: TranscriptRenderNode
    let terminalID: UUID?

    @State private var isHovered = false

    var body: some View {
        TranscriptRow(node: node, terminalID: terminalID)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.transcriptTextSelection, isHovered)
            .onHover { isHovered = $0 }
    }
}
