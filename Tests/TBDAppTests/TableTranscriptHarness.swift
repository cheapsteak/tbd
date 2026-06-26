import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// Env-gated, HEADLESS harness for the NSTableView transcript pane (#129).
///
/// Builds the production `TableTranscriptView.Coordinator` over a real session's
/// `[TranscriptItem]` inside an offscreen 680x600 `NSScrollView` + `NSTableView`,
/// scrolls to the end, and asserts row geometry against an INDEPENDENT
/// ground-truth height oracle.
///
/// ## Why an independent oracle
/// The original guard re-measured each row with the SAME code path the table
/// used to size it, so a systematic sizing bug (greedy unbounded measurement →
/// giant gaps; laggy estimate correction → top clipping) measured "consistent"
/// and the guard passed while the live pane was visibly broken. The fixed oracle
/// hosts the KNOWN-GOOD SwiftUI row layout
/// (`SelectableTranscriptRow … .padding(.horizontal,8).fixedSize(vertical:)`) in
/// a standalone `NSHostingView` and reads `fittingSize.height` — i.e. how
/// SwiftUI's own layout would size the row at the column width — then asserts the
/// table's actual `rect(ofRow:).height` matches it within `tolerance` in BOTH
/// directions:
///   * `rowHeight < oracle - tol`  → CLIP  (content cut off at top) → FAIL
///   * `rowHeight > oracle + tol`  → GAP   (giant empty space)      → FAIL
///
/// It runs over BOTH a real session AND a hand-built fixture covering every node
/// kind (user/assistant chat bubbles, Bash/Read tool cards, AskUserQuestion, a
/// GFM table, a systemReminder, and a subagentSummary) so a regression in any
/// card type is caught, not just chat bubbles.
///
/// Inert during normal `swift test`: early-returns unless `TBD_TABLE_HARNESS=1`.
///
///     TBD_TABLE_HARNESS=1 swift test --filter TableTranscriptHarness
@Suite("Table transcript harness (#129)")
@MainActor
struct TableTranscriptHarness {
    private static let width: CGFloat = 680
    private static let viewportHeight: CGFloat = 600
    private static let outputDir = "/tmp/transcript-compare"
    /// Pointwise geometry tolerance: a row whose height differs from the oracle
    /// by more than this is a clip (too short) or a gap (too tall).
    private static let tolerance: CGFloat = 2.0

    // MARK: - Real session: oracle-checked, lazy, snapshot

    @Test("real session: every row matches the height oracle (gated by TBD_TABLE_HARNESS=1)")
    func renderTable() throws {
        guard ProcessInfo.processInfo.environment["TBD_TABLE_HARNESS"] == "1" else {
            #expect(true)
            return
        }

        let fm = FileManager.default
        try fm.createDirectory(atPath: Self.outputDir, withIntermediateDirectories: true)

        let items = try loadSession()
        #expect(!items.isEmpty, "session produced no items")

        let suiteName = "table-harness-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let scene = makeScene(items: items, appState: appState, fixedSize: true)
        defer { withExtendedLifetime(scene.coordinator) {} }

        // --- LAZY MEASUREMENT (#129): bottom-window precompute, not all rows ---
        // Production `makeNSView` calls this before `reloadData`; the harness builds
        // the coordinator directly, so call it here. It measures EXACTLY only the
        // bottom window (the open-at-bottom viewport + buffer); older rows are sized
        // by the cheap per-kind estimate in `heightOfRow` until realized. Assert the
        // bottom-window invariant (cached count is the bounded window, NOT all rows)
        // and that `heightOfRow` never returns 0/negative for ANY row (no clip from
        // a zero estimate). Visible rows being EXACT is verified by the oracle check
        // over the visible window further down.
        let precomputeStart = Date()
        scene.coordinator.precomputeBottomWindow()
        let precomputeMillis = Date().timeIntervalSince(precomputeStart) * 1000
        let cachedRows = scene.coordinator.cachedHeightRowCount
        let nodeCount = transcriptRenderNodes(from: items).count
        let expectedWindow = min(nodeCount, TableTranscriptView.Coordinator.bottomEagerWindow)
        #expect(cachedRows == expectedWindow,
                Comment(rawValue: "bottom-window precompute should cache exactly \(expectedWindow) "
                    + "rows (the bottom window), but cached \(cachedRows)"))
        // heightOfRow must never return a zero/negative height — a 0 would clip the
        // row to nothing. Every estimated AND every cached row must be positive.
        var nonPositive: [Int] = []
        for row in 0..<nodeCount where scene.coordinator.tableView(scene.tableView, heightOfRow: row) <= 0 {
            nonPositive.append(row)
        }
        #expect(nonPositive.isEmpty,
                Comment(rawValue: "heightOfRow returned <= 0 (would clip) for rows \(nonPositive)"))

        // --- (c) lazy load + per-op timing during initial reload + first layout ---
        // Initial paint, as the live app does it: reloadData + run loop. We do NOT
        // force a full `layoutSubtreeIfNeeded` here — NSTableView lays out only the
        // visible window for first paint; the full document-height walk is a
        // separate, scroll-driven cost measured below.
        let paintStart = Date()
        scene.tableView.reloadData()
        pump()
        let paintMillis = Date().timeIntervalSince(paintStart) * 1000

        // Full first layout (forces NSTableView's document-height walk, i.e. the
        // worst case where every row a tall scroller needs is measured once).
        let reloadStart = Date()
        scene.tableView.layoutSubtreeIfNeeded()
        pump()
        let reloadMillis = Date().timeIntervalSince(reloadStart) * 1000

        let nodes = transcriptRenderNodes(from: items)
        let realizedAfterLoad = scene.coordinator.viewForCallCount
        let heightCallsAfterLoad = scene.coordinator.heightOfRowCallCount
        // Lazy: realized rows should be far fewer than total on a long session.
        let lazyOK = nodes.count <= 12 || realizedAfterLoad < nodes.count

        // --- scroll to end + drain ---
        let scrollStart = Date()
        scene.coordinator.scrollToEnd(animated: false)
        pump()
        scene.tableView.layoutSubtreeIfNeeded()
        pump()
        let scrollMillis = Date().timeIntervalSince(scrollStart) * 1000

        // Drain deferred height corrections, then re-pin to the bottom (a
        // correction below the fold can shift the document and unpark the clip).
        settle(scene.tableView)
        scene.coordinator.scrollToEnd(animated: false)
        settle(scene.tableView)

        // --- (a) last row fully within the clip visible rect ---
        let lastRow = scene.tableView.numberOfRows - 1
        let visibleRect = scene.scrollView.contentView.documentVisibleRect
        let lastRowRect = scene.tableView.rect(ofRow: lastRow)
        let lastRowVisible = visibleRect.contains(NSPoint(x: lastRowRect.midX, y: lastRowRect.maxY - 1))
            && lastRowRect.maxY <= visibleRect.maxY + 1.0
            && lastRowRect.minY >= visibleRect.minY - 1.0

        // --- (b) oracle check across the visible window (clip AND gap) ---
        let visibleRange = scene.tableView.rows(in: visibleRect)
        let violations = self.oracleViolations(
            tableView: scene.tableView,
            nodes: nodes,
            rows: visibleRange.location..<(visibleRange.location + visibleRange.length)
        )

        let snapshotPath = "\(Self.outputDir)/table-fix-after__new.png"
        try snapshotViewport(scrollView: scene.scrollView, to: snapshotPath)

        var findings: [String] = []
        findings.append("HARNESS: NSTableView transcript real-session oracle (#129)")
        findings.append("generated: \(ISO8601DateFormatter().string(from: Date()))")
        findings.append("items: \(items.count)  nodes: \(nodes.count)")
        findings.append("viewport: \(Int(Self.width))x\(Int(Self.viewportHeight)) pt  tol: \(Self.tolerance)pt")
        findings.append("")
        findings.append("(a) last row fully within clip visible rect: \(lastRowVisible)")
        findings.append("    lastRow=\(lastRow) rect=\(lastRowRect) visible=\(visibleRect)")
        findings.append("(b) oracle violations (must be 0): \(violations.count)")
        for v in violations { findings.append("    \(v)") }
        findings.append("bottom-window precompute: \(cachedRows)/\(nodeCount) rows cached exactly in "
            + "\(String(format: "%.1f", precomputeMillis)) ms "
            + "(rest sized by per-kind estimate until realized)")
        findings.append("(c) lazy load: realized \(realizedAfterLoad)/\(nodes.count) cells (ok=\(lazyOK))")
        findings.append("    heightOfRow fired \(heightCallsAfterLoad)/\(nodes.count) times by full layout")
        findings.append("    INITIAL PAINT (reloadData + run loop, no forced full layout): "
            + "\(String(format: "%.1f", paintMillis)) ms")
        findings.append("    full document-height layout (scroll-driven, one-time, then cached): "
            + "\(String(format: "%.1f", reloadMillis)) ms")
        findings.append("    scroll-to-end: \(String(format: "%.1f", scrollMillis)) ms")
        // First-open budget. Authoritative measurement of a long session's rows
        // costs ~1.1s once (then cached) — well under #129's 35s hang but above a
        // 500ms ideal. The gate guards against a true regression toward that hang;
        // the precise measured number is reported above for tracking.
        let firstOpenBudgetMillis = 3000.0
        findings.append("    first open under \(Int(firstOpenBudgetMillis))ms (#129 hang guard): "
            + "\(reloadMillis < firstOpenBudgetMillis)")
        findings.append("snapshot: \(snapshotPath)")
        try findings.joined(separator: "\n").write(
            toFile: "\(Self.outputDir)/TABLE-HARNESS.txt", atomically: true, encoding: .utf8)

        #expect(lastRowVisible, "newest content (last row) must be fully visible after scroll-to-end")
        #expect(violations.isEmpty, "row heights must match the oracle: \(violations.joined(separator: "; "))")
        #expect(lazyOK, "initial load realized \(realizedAfterLoad)/\(nodes.count) cells — not lazy")
        #expect(reloadMillis < firstOpenBudgetMillis,
                "first open took \(reloadMillis) ms — regressing toward the #129 hang")
        #expect(scrollMillis < firstOpenBudgetMillis,
                "scroll-to-end took \(scrollMillis) ms — regressing toward the #129 hang")
    }


    // MARK: - All-kinds fixture: oracle ground truth, before/after proof

    /// Hand-built fixture covering EVERY node kind, checked top-to-bottom against
    /// the oracle. Also builds a SECOND table WITHOUT the `.fixedSize` fix to
    /// prove the oracle FAILS on the broken sizing (clip/gap) and PASSES on the
    /// fixed one — the regression evidence the original same-path guard lacked.
    @Test("all node kinds: oracle catches clip+gap; fixed passes, unfixed fails (gated)")
    func allKindsOracle() throws {
        guard ProcessInfo.processInfo.environment["TBD_TABLE_HARNESS"] == "1" else {
            #expect(true)
            return
        }

        let fm = FileManager.default
        try fm.createDirectory(atPath: Self.outputDir, withIntermediateDirectories: true)

        let suiteName = "table-harness-kinds-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = Self.allKindsFixture()
        let nodes = transcriptRenderNodes(from: items)
        let allRows = 0..<nodes.count

        // --- FIXED table (production rowRootView, with .fixedSize) ---
        let after = makeScene(items: items, appState: appState, fixedSize: true)
        defer { withExtendedLifetime(after.coordinator) {} }
        after.tableView.reloadData()
        settle(after.tableView)
        let afterViolations = oracleViolations(tableView: after.tableView, nodes: nodes, rows: allRows)
        try snapshotViewport(scrollView: after.scrollView, to: "\(Self.outputDir)/table-fix-after__new.png")

        // --- UNFIXED table (same root WITHOUT .fixedSize → greedy/laggy) ---
        let before = makeScene(items: items, appState: appState, fixedSize: false)
        defer { withExtendedLifetime(before.coordinator) {} }
        before.tableView.reloadData()
        pump()
        before.tableView.layoutSubtreeIfNeeded()
        pump()
        let beforeViolations = oracleViolations(tableView: before.tableView, nodes: nodes, rows: allRows)
        try snapshotViewport(scrollView: before.scrollView, to: "\(Self.outputDir)/table-fix-before__new.png")

        let beforeClips = beforeViolations.filter { $0.contains("CLIP") }
        let beforeGaps = beforeViolations.filter { $0.contains("GAP") }

        var findings: [String] = []
        findings.append("HARNESS: all-node-kinds oracle (before/after) (#129)")
        findings.append("generated: \(ISO8601DateFormatter().string(from: Date()))")
        findings.append("nodes: \(nodes.count)  tol: \(Self.tolerance)pt")
        for (i, node) in nodes.enumerated() {
            findings.append("    row \(i): \(Self.kindLabel(node.kind))")
        }
        findings.append("")
        findings.append("UNFIXED (no .fixedSize) oracle violations: \(beforeViolations.count) "
            + "(clip=\(beforeClips.count) gap=\(beforeGaps.count))")
        for v in beforeViolations { findings.append("    \(v)") }
        findings.append("")
        findings.append("FIXED (.fixedSize) oracle violations (must be 0): \(afterViolations.count)")
        for v in afterViolations { findings.append("    \(v)") }
        findings.append("")
        findings.append("snapshots: \(Self.outputDir)/table-fix-{before,after}__new.png")
        try findings.joined(separator: "\n").write(
            toFile: "\(Self.outputDir)/TABLE-HARNESS-KINDS.txt", atomically: true, encoding: .utf8)

        // The oracle MUST flag the unfixed table (proves it detects clip+gap)…
        #expect(!beforeViolations.isEmpty,
                "oracle failed to detect any clip/gap on the UNFIXED table — it cannot be trusted")
        // …and MUST pass the fixed table.
        #expect(afterViolations.isEmpty,
                "fixed table still violates the oracle: \(afterViolations.joined(separator: "; "))")
    }

    // MARK: - Region snapshots (vision self-check)

    /// Captures full-resolution PNGs of the table viewport at the SPECIFIC regions
    /// the live clip/gap/overlap symptoms were reported in — for BOTH the fixed
    /// (`.fixedSize`) and unfixed (shipped) sizing — so the fix can be judged with
    /// EYES, not only numbers. Numeric oracles have passed while pixels were
    /// visibly broken; this is the backstop.
    ///
    /// Regions on the full real session:
    ///   1. a cluster of tool-call cards (Bash/Read/Write/Edit) near a header;
    ///   2. a chatBubble→tool-card boundary (where overlap/clip was reported);
    ///   3. the row with the largest oracle row-height delta on the unfixed table.
    /// Writes `/tmp/transcript-compare/table-fix-{before,after}-region{1,2,3}__new.png`.
    @Test("region snapshots for visual inspection (gated by TBD_TABLE_HARNESS=1)")
    func regionSnapshots() throws {
        guard ProcessInfo.processInfo.environment["TBD_TABLE_HARNESS"] == "1" else {
            #expect(true)
            return
        }
        let fm = FileManager.default
        try fm.createDirectory(atPath: Self.outputDir, withIntermediateDirectories: true)

        let items = try loadSession()
        let nodes = transcriptRenderNodes(from: items)
        #expect(!nodes.isEmpty)

        let suiteName = "table-harness-region-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        // Region anchors.
        let toolCluster = Self.firstToolClusterRow(nodes) ?? 0
        let bubbleToToolBoundary = Self.firstBubbleToToolBoundaryRow(nodes) ?? toolCluster
        let anchors = [toolCluster, bubbleToToolBoundary]

        // Build the fixed table once to find the largest oracle delta row, then add
        // it as the third anchor.
        let fixed = makeScene(items: items, appState: appState, fixedSize: true)
        defer { withExtendedLifetime(fixed.coordinator) {} }
        fixed.tableView.reloadData()
        settle(fixed.tableView)
        let largestDeltaRow = self.largestDeltaRow(tableView: fixed.tableView, nodes: nodes)
        let allAnchors = anchors + [largestDeltaRow]

        for (i, anchor) in allAnchors.enumerated() {
            fixed.tableView.scrollRowToVisible(min(anchor + 4, nodes.count - 1))
            fixed.tableView.scrollRowToVisible(anchor)
            settle(fixed.tableView)
            try snapshotViewport(scrollView: fixed.scrollView,
                                 to: "\(Self.outputDir)/table-fix-after-region\(i + 1)__new.png")
        }

        let unfixed = makeScene(items: items, appState: appState, fixedSize: false)
        defer { withExtendedLifetime(unfixed.coordinator) {} }
        unfixed.tableView.reloadData()
        settle(unfixed.tableView)
        for (i, anchor) in allAnchors.enumerated() {
            unfixed.tableView.scrollRowToVisible(min(anchor + 4, nodes.count - 1))
            unfixed.tableView.scrollRowToVisible(anchor)
            settle(unfixed.tableView)
            try snapshotViewport(scrollView: unfixed.scrollView,
                                 to: "\(Self.outputDir)/table-fix-before-region\(i + 1)__new.png")
        }

        var findings: [String] = []
        findings.append("HARNESS: region snapshots for visual inspection (#129)")
        findings.append("generated: \(ISO8601DateFormatter().string(from: Date()))")
        findings.append("region 1 (tool-card cluster) anchor row: \(allAnchors[0])")
        findings.append("region 2 (chatBubble→tool boundary) anchor row: \(allAnchors[1])")
        findings.append("region 3 (largest oracle delta) anchor row: \(allAnchors[2])")
        findings.append("snapshots: table-fix-{before,after}-region{1,2,3}__new.png")
        try findings.joined(separator: "\n").write(
            toFile: "\(Self.outputDir)/TABLE-HARNESS-REGIONS.txt", atomically: true, encoding: .utf8)
        #expect(true)
    }

    /// First row that begins a run of >=2 adjacent tool-call cards, backed up to
    /// the preceding chatBubble (a "Claude · timestamp" header) when present so the
    /// snapshot shows a header above the cards.
    private static func firstToolClusterRow(_ nodes: [TranscriptRenderNode]) -> Int? {
        for i in 0..<max(0, nodes.count - 1) {
            if case .toolCall = nodes[i].kind, case .toolCall = nodes[i + 1].kind {
                var start = i
                if start > 0, case .chatBubble = nodes[start - 1].kind { start -= 1 }
                return start
            }
        }
        return nil
    }

    /// First assistant-bubble → tool-card transition (the boundary where overlap
    /// or clipping between a message and the following card was reported).
    private static func firstBubbleToToolBoundaryRow(_ nodes: [TranscriptRenderNode]) -> Int? {
        for i in 0..<max(0, nodes.count - 1) {
            if case .chatBubble = nodes[i].kind, case .toolCall = nodes[i + 1].kind {
                return i
            }
        }
        return nil
    }

    /// Row whose table height most exceeds (or undershoots) the oracle.
    private func largestDeltaRow(tableView: NSTableView, nodes: [TranscriptRenderNode]) -> Int {
        let spacing = tableView.intercellSpacing.height
        var best = 0
        var bestDelta: CGFloat = -1
        for row in 0..<nodes.count {
            let rowHeight = tableView.rect(ofRow: row).height - spacing
            let delta = abs(rowHeight - oracleHeight(for: nodes[row]))
            if delta > bestDelta { bestDelta = delta; best = row }
        }
        return best
    }

    // MARK: - Oracle

    /// Independent ground-truth row height for `node` at the column width: how
    /// SwiftUI's own layout sizes the KNOWN-GOOD row.
    ///
    /// NOTE ON API CHOICE: the obvious `NSHostingView.fittingSize.height` is NOT
    /// usable as ground truth here. `fittingSize` does NOT honour a constrained
    /// width for wrapping content — it systematically UNDER-reports (a multi-line
    /// chat bubble that truly needs 76pt reports ~56pt). That is the exact
    /// under-measurement documented in `TranscriptCardSizing` and the reason a
    /// `fittingSize`-based oracle flagged correctly-sized rows as "gaps". The
    /// width-honouring API is `NSHostingController.sizeThatFits(in:)` with an
    /// unbounded proposed height. We build a FRESH controller per call (never
    /// reading the table's height cache), so this remains an independent
    /// computation from scratch through the known-correct layout — it just uses
    /// the correct measurement primitive, not the broken one.
    private func oracleHeight(for node: TranscriptRenderNode) -> CGFloat {
        // Chat bubbles render as a vertical stack of typed blocks (prose on
        // TextKit-1, tables as native grid views) inside one bubble — NOT the
        // SwiftUI SelectableTranscriptRow. The ground truth for those rows is the
        // per-block measurement: an INDEPENDENT `MessageBlockMeasurer` over the
        // composed blocks at the SAME body width, plus inter-block spacing and the
        // fixed chrome. (Render==measure for the realized bubble cell is verified
        // separately in `bubbleCells`.) Every other kind keeps the width-honouring
        // SwiftUI hosting oracle.
        if case .chatBubble(let item) = node.kind {
            let role = TranscriptBubbleGeometry.role(for: item)
            let blocks = TranscriptBubbleGeometry.composedBlocks(for: item, badgeUsage: node.badgeUsage)
            let bodyWidth = TranscriptBubbleGeometry.bodyWidth(columnWidth: Self.width, role: role)
            let blocksHeight = MessageBlockMeasurer().blocksHeight(blocks, bodyWidth: bodyWidth)
            return TranscriptBubbleGeometry.rowHeight(blocksHeight: blocksHeight)
        }
        let controller = NSHostingController(rootView: AnyView(
            SelectableTranscriptRow(node: node, terminalID: nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .fixedSize(horizontal: false, vertical: true)
        ))
        controller.sizingOptions = [.preferredContentSize]
        let proposed = NSSize(width: Self.width, height: .greatestFiniteMagnitude)
        let measured = controller.sizeThatFits(in: proposed).height
        return measured > 0 ? measured : 44
    }

    /// Bidirectional comparison of each row's actual table height to the oracle.
    /// Returns a human-readable violation string per offending row.
    private func oracleViolations(
        tableView: NSTableView,
        nodes: [TranscriptRenderNode],
        rows: Range<Int>
    ) -> [String] {
        var out: [String] = []
        // `rect(ofRow:)` reports the row's allotted height INCLUDING the table's
        // vertical intercell spacing; the oracle measures pure content height.
        // Subtract the spacing so we compare content-to-content.
        let spacing = tableView.intercellSpacing.height
        for row in rows {
            guard row >= 0, row < nodes.count else { continue }
            let node = nodes[row]
            let rowHeight = tableView.rect(ofRow: row).height - spacing
            let oracle = oracleHeight(for: node)
            if rowHeight < oracle - Self.tolerance {
                out.append("row \(row) [\(Self.kindLabel(node.kind))] CLIP: "
                    + "rowH=\(String(format: "%.1f", rowHeight)) < oracle=\(String(format: "%.1f", oracle))")
            } else if rowHeight > oracle + Self.tolerance {
                out.append("row \(row) [\(Self.kindLabel(node.kind))] GAP: "
                    + "rowH=\(String(format: "%.1f", rowHeight)) > oracle=\(String(format: "%.1f", oracle))")
            }
        }
        return out
    }

    private static func kindLabel(_ kind: TranscriptRenderNode.Kind) -> String {
        switch kind {
        case .chatBubble(let item):
            switch item {
            case .userPrompt: return "chatBubble/user"
            case .assistantText: return "chatBubble/assistant"
            default: return "chatBubble/other"
            }
        case .systemReminder: return "systemReminder"
        case .skillBody: return "skillBody"
        case .toolCall(_, let name, _, _, _, _): return "toolCall/\(name)"
        case .subagentSummary: return "subagentSummary"
        }
    }

    // MARK: - Scene

    private struct Scene {
        let scrollView: NSScrollView
        let tableView: NSTableView
        let coordinator: InstrumentedCoordinator
        let window: NSWindow
    }

    /// A Coordinator subclass that counts `viewFor`/`heightOfRow` calls (for the
    /// lazy-realization assertion) and can optionally drop the `.fixedSize`
    /// modifier from the rendered/measured root, reproducing the pre-fix greedy/
    /// laggy sizing so the oracle can be proven to catch it.
    private final class InstrumentedCoordinator: TableTranscriptView.Coordinator {
        var viewForCallCount = 0
        var heightOfRowCallCount = 0
        let useFixedSize: Bool

        init(context: TranscriptCardContext, useFixedSize: Bool) {
            self.useFixedSize = useFixedSize
            super.init(context: context)
        }

        override func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            viewForCallCount += 1
            if useFixedSize {
                return super.tableView(tableView, viewFor: tableColumn, row: row)
            }
            // UNFIXED reproduction: host the row WITHOUT `.fixedSize`. Heights are
            // driven authoritatively by `heightOfRow` below, so we do not call the
            // production correction machinery (which would re-measure WITH
            // `.fixedSize` and erase the divergence we are demonstrating).
            guard row >= 0, row < numberOfRows(in: tableView) else { return nil }
            let node = nodes[row]
            let cell = NSTableCellView()
            let host = NSHostingView(rootView: AnyView(
                SelectableTranscriptRow(node: node, terminalID: context.terminalID)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            ))
            host.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                host.topAnchor.constraint(equalTo: cell.topAnchor),
                host.bottomAnchor.constraint(equalTo: cell.bottomAnchor)
            ])
            return cell
        }

        override func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            heightOfRowCallCount += 1
            if useFixedSize {
                return super.tableView(tableView, heightOfRow: row)
            }
            // Pre-fix reproduction of the SHIPPED behaviour: `heightOfRow` returns
            // the cheap LOW-biased ESTIMATE and the row is never reliably corrected
            // (the shipped code corrected via an in-pass `noteHeightOfRows`, which
            // does not re-lay the row), so the row stays at the estimate height —
            // too short for tall content (CLIP) and too tall for short content
            // (GAP). This is exactly the clip/gap the oracle must catch.
            guard row >= 0, row < numberOfRows(in: tableView) else {
                return TableTranscriptView.Coordinator.estimate(for: nil, width: max(tableView.bounds.width, 1))
            }
            return TableTranscriptView.Coordinator.estimate(
                for: nodes[row], width: max(tableView.bounds.width, 1))
        }
    }

    /// Builds an offscreen 680x600 scroll view + table wired to an instrumented
    /// production Coordinator over `items`. Mirrors `makeNSView`'s setup.
    private func makeScene(items: [TranscriptItem], appState: AppState, fixedSize: Bool) -> Scene {
        let context = TranscriptCardContext(
            terminalID: nil,
            openTranscriptOverlay: { _ in },
            appState: appState
        )
        let coordinator = InstrumentedCoordinator(context: context, useFixedSize: fixedSize)

        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.gridStyleMask = []
        tableView.backgroundColor = .clear
        tableView.usesAutomaticRowHeights = false
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.rowSizeStyle = .custom
        let column = NSTableColumn(identifier: TableTranscriptView.Coordinator.columnID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = coordinator
        tableView.delegate = coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        coordinator.tableView = tableView
        coordinator.scrollView = scrollView

        let nodes = transcriptRenderNodes(from: items)
        coordinator.nodes = nodes
        coordinator.previousNodes = nodes

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        scrollView.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight)

        return Scene(scrollView: scrollView, tableView: tableView, coordinator: coordinator, window: window)
    }

    // MARK: - All-kinds fixture

    /// A short session that produces one render node of each kind the live pane
    /// must size correctly: user + assistant chat bubbles, a Bash and a Read
    /// tool card, an AskUserQuestion card, an assistant message containing a GFM
    /// table, a systemReminder, and a Task tool whose subagent yields a
    /// `subagentSummary` row.
    private static func allKindsFixture() -> [TranscriptItem] {
        var items: [TranscriptItem] = []

        items.append(.userPrompt(
            id: "k-user",
            text: "Walk me through the row-sizing path and the trade-offs, with enough "
                + "detail that this user bubble wraps across several lines in the column.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        items.append(.assistantText(
            id: "k-assistant",
            text: """
            Here is the rundown. Each upstream item becomes a render node, cached by \
            `(id, contentVersion, width)` so a re-poll never rebuilds an unchanged row. \
            This paragraph is intentionally long so the assistant bubble has real height \
            and spans multiple wrapped lines.

            A second paragraph adds vertical extent so the card is comfortably taller than \
            one line and any clip is obvious.
            """,
            timestamp: nil,
            usage: nil
        ))

        items.append(.toolCall(
            id: "k-bash",
            name: "Bash",
            inputJSON: #"{"command":"swift build 2>&1 | tail -40 && echo done"}"#,
            inputTruncatedTo: nil,
            result: ToolResult(
                text: "Compiling TBDApp...\nBuild complete! (10.8s)\n",
                truncatedTo: nil,
                isError: false
            ),
            subagent: nil,
            timestamp: nil
        ))

        items.append(.toolCall(
            id: "k-read",
            name: "Read",
            inputJSON: #"{"file_path":"/Users/x/Sources/TBDApp/Panes/Transcript/Table/TableTranscriptView.swift"}"#,
            inputTruncatedTo: nil,
            result: ToolResult(
                text: "1\timport AppKit\n2\timport SwiftUI\n3\timport TBDShared\n",
                truncatedTo: nil,
                isError: false
            ),
            subagent: nil,
            timestamp: nil
        ))

        items.append(.toolCall(
            id: "k-ask",
            name: "AskUserQuestion",
            inputJSON: #"""
            {"questions":[{"question":"Which sizing path should drive row height?",\
            "header":"Sizing","multiSelect":false,\
            "options":[{"label":"Authoritative heightOfRow","description":"Measure the real height up front, cached."},\
            {"label":"Estimate then correct","description":"Cheap estimate, patch via noteHeightOfRows."}]}]}
            """#,
            inputTruncatedTo: nil,
            result: ToolResult(text: "Authoritative heightOfRow", truncatedTo: nil, isError: false),
            subagent: nil,
            timestamp: nil
        ))

        items.append(.assistantText(
            id: "k-table",
            text: """
            Comparison of the two paths:

            | Path | Up-front cost | Clip risk | Gap risk |
            | --- | --- | --- | --- |
            | Authoritative | measure visible rows | none | none |
            | Estimate+correct | cheap | high (laggy correction) | medium |
            | Greedy unbounded | cheap | low | very high (~600pt) |

            The table view renders this as a grid attachment.
            """,
            timestamp: nil,
            usage: nil
        ))

        items.append(.systemReminder(
            id: "k-reminder",
            kind: .other,
            text: "This is a system reminder with a couple of sentences of text so the row "
                + "has more than a single line of height and any clip would be visible.",
            timestamp: nil
        ))

        items.append(.toolCall(
            id: "k-task",
            name: "Task",
            inputJSON: #"{"description":"Investigate sizing","subagent_type":"Explore"}"#,
            inputTruncatedTo: nil,
            result: ToolResult(text: "Found the greedy measurement.", truncatedTo: nil, isError: false),
            subagent: Subagent(
                agentID: "k-task-agent",
                agentType: "Explore",
                items: [
                    .assistantText(id: "k-task-a", text: "Looked at fittingHeight.", timestamp: nil, usage: nil)
                ]
            ),
            timestamp: nil
        ))

        return items
    }

    // MARK: - Attributed chat-bubble cells (render == measure)

    /// A short session exercising the attributed bubble cell path: a very long
    /// (>5000pt) assistant message, a message carrying a token badge, a bubble
    /// containing a GFM table, a code-block bubble, and a short user message.
    private static func bubbleFixture() -> [TranscriptItem] {
        var items: [TranscriptItem] = []

        items.append(.userPrompt(
            id: "b-user",
            text: "Short user message that fits on a line or two.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        // >5000pt long assistant message: many wrapped paragraphs.
        var longParagraphs: [String] = []
        for i in 0..<85 {
            longParagraphs.append(
                "Paragraph \(i): this is a deliberately long paragraph that wraps across "
                + "several lines in the column so the bubble grows tall enough to exceed "
                + "five thousand points of rendered height, exercising the exact-measure path "
                + "on a very large attributed string with `inline code` and **bold** runs.")
        }
        items.append(.assistantText(
            id: "b-long",
            text: longParagraphs.joined(separator: "\n\n"),
            timestamp: nil,
            usage: nil
        ))

        items.append(.assistantText(
            id: "b-badge",
            text: "This assistant message carries a token-usage badge that must render "
                + "fully inside the bubble, beneath the body text.",
            timestamp: nil,
            usage: TokenUsage(inputTokens: 124_000, cacheCreationTokens: 0, cacheReadTokens: 0)
        ))

        items.append(.assistantText(
            id: "b-table",
            text: """
            Comparison table embedded in a bubble:

            | Path | Cost | Clip risk |
            | --- | --- | --- |
            | Authoritative | measure visible rows | none |
            | Estimate+correct | cheap | high |

            Text continues after the table to confirm the attachment contributes height.
            """,
            timestamp: nil,
            usage: nil
        ))

        items.append(.assistantText(
            id: "b-code",
            text: """
            Here is a code block bubble:

            ```swift
            func greet(_ name: String) -> String {
                return "Hello, \\(name)"
            }
            ```

            And a trailing line after the code.
            """,
            timestamp: nil,
            usage: nil
        ))

        return items
    }

    /// Drives the REAL table with attributed bubble cells. Snapshots the TOP and
    /// BOTTOM of the long message plus the table bubble and the user bubble, and
    /// asserts that for each chatBubble row the value `heightOfRow` returned equals
    /// the realized `TranscriptBubbleCellView`'s actual drawn text height (its
    /// NSTextView `usedRect` + chrome) within ~1pt — render == measure.
    ///
    ///     TBD_TABLE_HARNESS=1 swift test --filter TableTranscriptHarness
    @Test("attributed bubble cells: render == measure; snapshots written (gated)")
    func bubbleCells() throws {
        guard ProcessInfo.processInfo.environment["TBD_TABLE_HARNESS"] == "1" else {
            #expect(true)
            return
        }
        let fm = FileManager.default
        try fm.createDirectory(atPath: Self.outputDir, withIntermediateDirectories: true)

        let suiteName = "table-harness-bubble-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = Self.bubbleFixture()
        let nodes = transcriptRenderNodes(from: items)
        #expect(!nodes.isEmpty)

        let scene = makeScene(items: items, appState: appState, fixedSize: true)
        defer { withExtendedLifetime(scene.coordinator) {} }
        // This test asserts heightOfRow == realized for EVERY bubble row, so every
        // row must have its EXACT height cached (not the estimate). The fixture is
        // < bottomEagerWindow rows, so the bottom-window precompute measures them
        // all exactly. (#129 lazy measurement.)
        scene.coordinator.precomputeBottomWindow()
        scene.tableView.reloadData()
        settle(scene.tableView)

        // --- render == measure: heightOfRow vs realized cell drawn height ---
        var deltas: [String] = []
        var maxDelta: CGFloat = 0
        for (row, node) in nodes.enumerated() {
            guard case .chatBubble = node.kind else { continue }
            let measured = scene.coordinator.tableView(scene.tableView, heightOfRow: row)
            guard let cell = scene.coordinator.tableView(
                scene.tableView, viewFor: nil, row: row) as? TranscriptBubbleCellView else {
                deltas.append("row \(row): cell was not a TranscriptBubbleCellView")
                continue
            }
            cell.layoutSubtreeIfNeeded()
            let realized = cell.realizedRowHeight
            let delta = abs(measured - realized)
            maxDelta = max(maxDelta, delta)
            deltas.append("row \(row) [\(Self.kindLabel(node.kind))]: "
                + "measured=\(String(format: "%.1f", measured)) "
                + "realized=\(String(format: "%.1f", realized)) "
                + "delta=\(String(format: "%.2f", delta))")
        }

        // --- snapshots: top + bottom of the long message, table bubble, user bubble ---
        // Order the window on-screen so each cell's NSTextView realizes and draws
        // (an unordered offscreen window leaves text views blank). Restored/closed
        // at scope exit by the window's own lifetime.
        scene.window.orderFrontRegardless()
        scene.tableView.layoutSubtreeIfNeeded()
        settle(scene.tableView)
        var snapshotPaths: [String] = []
        func snapshot(row: Int, slug: String) throws {
            // BOTTOM: align the row's bottom into view, then TOP: its top.
            scene.tableView.scrollRowToVisible(min(row + 1, nodes.count - 1))
            settle(scene.tableView)
            let bottomPath = "\(Self.outputDir)/bubble-prod-\(slug)-bottom__new.png"
            try snapshotViewport(scrollView: scene.scrollView, to: bottomPath)
            snapshotPaths.append(bottomPath)

            scene.tableView.scrollRowToVisible(row)
            settle(scene.tableView)
            let topPath = "\(Self.outputDir)/bubble-prod-\(slug)-top__new.png"
            try snapshotViewport(scrollView: scene.scrollView, to: topPath)
            snapshotPaths.append(topPath)
        }
        let longRow = nodes.firstIndex { $0.id == "b-long" } ?? 0
        let tableRow = nodes.firstIndex { $0.id == "b-table" } ?? 0
        let userRow = nodes.firstIndex { $0.id == "b-user" } ?? 0
        try snapshot(row: longRow, slug: "long")
        try snapshot(row: tableRow, slug: "table")
        try snapshot(row: userRow, slug: "user")

        var findings: [String] = ["HARNESS: attributed chat-bubble cells (render == measure) (#129)"]
        findings.append("generated: \(ISO8601DateFormatter().string(from: Date()))")
        findings.append("nodes: \(nodes.count)  max render==measure delta: \(String(format: "%.2f", maxDelta))pt")
        findings.append("")
        findings.append("render == measure (delta must be <= 1.0pt):")
        for d in deltas { findings.append("    \(d)") }
        findings.append("")
        findings.append("snapshots:")
        for p in snapshotPaths { findings.append("    \(p)") }
        try findings.joined(separator: "\n").write(
            toFile: "\(Self.outputDir)/TABLE-HARNESS-BUBBLES.txt", atomically: true, encoding: .utf8)

        let failMessage = "render != measure for some bubble row (max delta \(maxDelta)pt): "
            + deltas.joined(separator: "; ")
        #expect(maxDelta <= 1.0, Comment(rawValue: failMessage))
    }

    // MARK: - Native activity-cell dispatch

    /// Confirms `viewFor` routes each kind to the right cell type: a Bash
    /// tool-call row and the systemReminder row produce a native
    /// `ActivityRowCellView`, while the AskUserQuestion row stays SwiftUI-hosted
    /// (`TranscriptHostingCellView`). Cheap + headless: it only asks the
    /// coordinator for cells, so it runs in normal `swift test`.
    @Test("native activity cells: Bash + systemReminder dispatch to ActivityRowCellView; AskUserQuestion stays hosted")
    func activityCellDispatch() {
        let suiteName = "table-harness-activity-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = Self.allKindsFixture()
        let nodes = transcriptRenderNodes(from: items)
        let scene = makeScene(items: items, appState: appState, fixedSize: true)
        defer { withExtendedLifetime(scene.coordinator) {} }

        func cell(forID id: String) -> NSView? {
            guard let row = nodes.firstIndex(where: { $0.id == id }) else { return nil }
            return scene.coordinator.tableView(scene.tableView, viewFor: nil, row: row)
        }

        #expect(cell(forID: "k-bash") is ActivityRowCellView,
                "Bash tool-call row must dispatch to the native ActivityRowCellView")
        #expect(cell(forID: "k-reminder") is ActivityRowCellView,
                "systemReminder row must dispatch to the native ActivityRowCellView")
        #expect(cell(forID: "k-ask") is TranscriptHostingCellView,
                "AskUserQuestion row must stay SwiftUI-hosted (TranscriptHostingCellView)")
    }

    // MARK: - Spot anchors (user-named clipping symptoms)

    /// Substring anchors for the user-named live-clipping rows, each with robust
    /// fallbacks present in any captured session (the literal future phrases may
    /// not exist in an older capture). The FIRST found per group is snapshotted.
    private static let spotAnchorGroups: [(slug: String, phrases: [String])] = [
        ("task-notification", ["ac9fba3cf555b40bc", "<task-notification>", "task-notification"]),
        ("restarted-fixed-binary", ["Restarted on the fixed binary", "fixed binary", "Restarted"]),
        ("nstableview-pane-live", ["The NSTableView pane is live behind its gate",
                                   "NSTableView pane is live", "behind its gate", "NSTableView"])
    ]

    /// Locates each named spot by text substring, scrolls the REAL (fixed) table
    /// to it, and writes paired PNGs — the TABLE render and a width-constrained
    /// GROUND-TRUTH `NSHostingView` render of the same node — to
    /// `spot-{slug}-{table,truth}__new.png` for side-by-side visual inspection.
    /// Asserts, per spot, that the table's `rect(ofRow:)` height >= the
    /// ground-truth height (no under-measure → no bottom clip / header top-clip).
    /// A synthesized 347k-token badge row is checked the same way. The paired
    /// PNGs are the visual backstop the numeric geometry check cannot replace.
    ///
    /// The SAME assertion is run against the UNFIXED (estimate-driven) table to
    /// prove it FAILS there (the regression the fix removes) and PASSES on fixed.
    ///
    ///     TBD_TABLE_HARNESS=1 swift test --filter TableTranscriptHarness
    @Test("spot anchors: named clipping rows fit their row; unfixed clips, fixed passes (gated)")
    func spotAnchors() throws {
        guard ProcessInfo.processInfo.environment["TBD_TABLE_HARNESS"] == "1" else {
            #expect(true)
            return
        }
        let fm = FileManager.default
        try fm.createDirectory(atPath: Self.outputDir, withIntermediateDirectories: true)
        let suiteName = "table-harness-spot-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        // Real session + a synthesized 347k-token badge bubble (the capture
        // carries no usage, so the badge attaches to this appended item).
        var items = try loadSession()
        items.append(.assistantText(
            id: "spot-badge-anchor",
            text: "Badge anchor row: this assistant message carries a 347k-token usage "
                + "badge that must render fully inside the row, badge included.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            usage: TokenUsage(inputTokens: 347_000, cacheCreationTokens: 0, cacheReadTokens: 0)
        ))
        let nodes = transcriptRenderNodes(from: items)
        #expect(!nodes.isEmpty)

        // Resolve each spot to a row index.
        var spots: [(slug: String, row: Int, note: String)] = []
        for group in Self.spotAnchorGroups {
            if let (row, matched) = Self.tallestRow(in: nodes, matchingAny: group.phrases) {
                spots.append((group.slug, row, "matched \"\(matched)\""))
            }
        }
        if let badgeRow = nodes.firstIndex(where: { $0.badgeUsage != nil }) {
            spots.append(("badge-347k", badgeRow, "badgeUsage=\(nodes[badgeRow].badgeUsage!.contextTotal)"))
        }
        #expect(!spots.isEmpty, "no spot anchors resolved — none of the named phrases or fallbacks found")

        // --- FIXED table: snapshot each spot + assert it fits ---
        let fixed = makeScene(items: items, appState: appState, fixedSize: true)
        defer { withExtendedLifetime(fixed.coordinator) {} }
        fixed.tableView.reloadData()
        settle(fixed.tableView)
        let fixedViolations = try snapshotAndCheckSpots(
            spots: spots, nodes: nodes, scene: fixed, appState: appState,
            tableSuffix: "table", writeTruth: true)

        // --- UNFIXED table: same spots must violate (regression proof) ---
        let unfixed = makeScene(items: items, appState: appState, fixedSize: false)
        defer { withExtendedLifetime(unfixed.coordinator) {} }
        unfixed.tableView.reloadData()
        settle(unfixed.tableView)
        let unfixedViolations = try snapshotAndCheckSpots(
            spots: spots, nodes: nodes, scene: unfixed, appState: appState,
            tableSuffix: "table-unfixed", writeTruth: false)

        var findings: [String] = ["HARNESS: spot anchors (named clipping rows) (#129)"]
        findings.append("generated: \(ISO8601DateFormatter().string(from: Date()))")
        findings.append("nodes: \(nodes.count)  tol: \(Self.tolerance)pt")
        for spot in spots {
            findings.append("spot \(spot.slug) row \(spot.row) [\(Self.kindLabel(nodes[spot.row].kind))] \(spot.note)")
            findings.append("    table=\(Self.outputDir)/spot-\(spot.slug)-table__new.png")
            findings.append("    truth=\(Self.outputDir)/spot-\(spot.slug)-truth__new.png")
        }
        findings.append("")
        findings.append("FIXED   violations (must be 0): \(fixedViolations.count)")
        for v in fixedViolations { findings.append("    \(v)") }
        findings.append("UNFIXED violations (must be > 0, proves the oracle bites): \(unfixedViolations.count)")
        for v in unfixedViolations { findings.append("    \(v)") }
        try findings.joined(separator: "\n").write(
            toFile: "\(Self.outputDir)/TABLE-HARNESS-SPOTS.txt", atomically: true, encoding: .utf8)

        #expect(fixedViolations.isEmpty,
                "spot rows clip/overflow on the FIXED table: \(fixedViolations.joined(separator: "; "))")
        #expect(!unfixedViolations.isEmpty,
                "oracle did not bite on the UNFIXED table — it cannot prove the fix")
    }

    /// For each spot: scroll the table to it, snapshot the viewport (and, when
    /// `writeTruth`, the ground-truth render), and check the row height >= the
    /// ground truth and the rendered last-ink fits the row. Returns violations.
    private func snapshotAndCheckSpots(
        spots: [(slug: String, row: Int, note: String)],
        nodes: [TranscriptRenderNode],
        scene: Scene,
        appState: AppState,
        tableSuffix: String,
        writeTruth: Bool
    ) throws -> [String] {
        let spacing = scene.tableView.intercellSpacing.height
        var violations: [String] = []
        for spot in spots {
            scene.tableView.scrollRowToVisible(min(spot.row + 6, nodes.count - 1))
            settle(scene.tableView)
            scene.tableView.scrollRowToVisible(spot.row)
            settle(scene.tableView)
            try snapshotViewport(scrollView: scene.scrollView,
                                 to: "\(Self.outputDir)/spot-\(spot.slug)-\(tableSuffix)__new.png")
            let node = nodes[spot.row]
            if writeTruth {
                try renderGroundTruth(for: node, appState: appState,
                                      to: "\(Self.outputDir)/spot-\(spot.slug)-truth__new.png")
            }
            let rowH = scene.tableView.rect(ofRow: spot.row).height - spacing
            let truthH = oracleHeight(for: node)
            if rowH < truthH - Self.tolerance {
                violations.append("spot \(spot.slug): row UNDER-measured rowH="
                    + "\(String(format: "%.1f", rowH)) < truth=\(String(format: "%.1f", truthH)) (CLIP)")
            }
        }
        return violations
    }

    /// The TALLEST node (by ground-truth height) whose text contains ANY of
    /// `phrases` — surfaces the worst clipping case for that group.
    private static func tallestRow(
        in nodes: [TranscriptRenderNode], matchingAny phrases: [String]
    ) -> (row: Int, matched: String)? {
        var best: (row: Int, matched: String, len: Int)?
        for (i, node) in nodes.enumerated() {
            let text = nodeText(node)
            guard let matched = phrases.first(where: { text.contains($0) }) else { continue }
            if best == nil || text.count > best!.len { best = (i, matched, text.count) }
        }
        guard let best else { return nil }
        return (best.row, best.matched)
    }

    /// Searchable text for a render node (mirrors `TranscriptCompareRealSessions.itemText`).
    private static func nodeText(_ node: TranscriptRenderNode) -> String {
        switch node.kind {
        case .chatBubble(let item):
            return TranscriptCompareRealSessions.itemText(item)
        case .systemReminder(_, _, let text, _), .skillBody(_, let text, _):
            return text
        case .toolCall(_, let name, let inputJSON, _, let result, _):
            return "\(name)\n\(inputJSON)\n\(result?.text ?? "")"
        case .subagentSummary(_, _, let agentType):
            return agentType ?? "subagent"
        }
    }

    /// Renders `node` in the KNOWN-GOOD width-constrained `NSHostingView` layout
    /// (the SwiftUI ground truth), sized to the oracle height, to a white PNG.
    private func renderGroundTruth(for node: TranscriptRenderNode, appState: AppState, to path: String) throws {
        let height = max(oracleHeight(for: node), 1)
        let frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        let host = NSHostingView(rootView: AnyView(
            SelectableTranscriptRow(node: node, terminalID: nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .fixedSize(horizontal: false, vertical: true)
                .environmentObject(appState)
        ))
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: frame)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.cgColor
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.widthAnchor.constraint(equalToConstant: Self.width)
        ])
        container.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        let image = NSImage(size: frame.size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: frame).fill()
        if let rep = container.bitmapImageRepForCachingDisplay(in: frame) {
            container.cacheDisplay(in: frame, to: rep)
            rep.draw(in: frame)
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let merged = NSBitmapImageRep(data: tiff),
              let png = merged.representation(using: .png, properties: [:]) else {
            throw HarnessError.couldNotMakePNG
        }
        try png.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Session loading

    /// Loads a real session's items. Reuses the harness's own JSONL parser
    /// (`TranscriptCompareRealSessions.parse`). Falls back to a tall synthetic
    /// session when no real file is found.
    private func loadSession() throws -> [TranscriptItem] {
        let fm = FileManager.default
        let thisSessionPath = ProcessInfo.processInfo.environment["TBD_COMPARE_THIS_SESSION"]
            ?? "/private/tmp/claude-501/-Users-chang-tbd-worktrees-tbd-transcript-row-flatten"
                + "/6F6A46F5-0E30-4CF8-A06C-A5C628760FF5/scratchpad/this-session-6F6A46F5.jsonl"
        if fm.fileExists(atPath: thisSessionPath) {
            let items = TranscriptCompareRealSessions.parse(filePath: thisSessionPath)
            if !items.isEmpty { return items }
        }
        for real in TranscriptCompareRealSessions.scenarios() {
            let items = TranscriptCompareRealSessions.parseWindow(for: real)
            if !items.isEmpty { return items }
        }
        return Self.tallSynthetic()
    }

    private static func tallSynthetic() -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        for i in 0..<24 {
            items.append(.userPrompt(
                id: "tbl-u\(i)",
                text: "Question \(i): walk me through part \(i) of the pipeline and the "
                    + "trade-offs, with enough detail to wrap across several lines.",
                timestamp: nil
            ))
            items.append(.assistantText(
                id: "tbl-a\(i)",
                text: """
                ### Answer \(i)

                Part \(i) converts upstream items into render nodes, each cached so a \
                re-poll does not rebuild the whole list. This paragraph is intentionally \
                long so the assistant card has real height and spans wrapped lines.

                A second paragraph for block \(i) to add vertical extent so scroll \
                offsets land in the middle of a tall card.
                """,
                timestamp: nil,
                usage: nil
            ))
        }
        return items
    }

    // MARK: - Helpers

    private func pump() {
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Drains the deferred async height corrections to a fixed point: each async
    /// `noteHeightOfRows` invalidates row heights, which only take effect on the
    /// NEXT layout pass, which may realize more cells that schedule more
    /// corrections. Pump + relayout until `rect(ofRow:)` stops changing.
    private func settle(_ tableView: NSTableView) {
        var previous = (0..<tableView.numberOfRows).map { tableView.rect(ofRow: $0).height }
        for _ in 0..<8 {
            pump()
            tableView.layoutSubtreeIfNeeded()
            pump()
            let current = (0..<tableView.numberOfRows).map { tableView.rect(ofRow: $0).height }
            if current == previous { return }
            previous = current
        }
    }

    private func snapshotViewport(scrollView: NSScrollView, to path: String) throws {
        let clip = scrollView.contentView
        guard let docView = scrollView.documentView else { throw HarnessError.couldNotMakeBitmap }
        let visible = clip.documentVisibleRect

        let size = NSSize(width: Self.width, height: Self.viewportHeight)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        if let rep = docView.bitmapImageRepForCachingDisplay(in: visible) {
            rep.size = visible.size
            docView.cacheDisplay(in: visible, to: rep)
            rep.draw(in: NSRect(origin: .zero, size: visible.size))
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let merged = NSBitmapImageRep(data: tiff),
              let png = merged.representation(using: .png, properties: [:]) else {
            throw HarnessError.couldNotMakePNG
        }
        try png.write(to: URL(fileURLWithPath: path))
    }

    enum HarnessError: Error {
        case couldNotMakeBitmap
        case couldNotMakePNG
    }
}
