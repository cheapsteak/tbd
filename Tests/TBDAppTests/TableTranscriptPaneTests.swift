import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// Headless tests of the NSTableView transcript pane (#129).
///
/// Each builds the production `TableTranscriptView.Coordinator` inside an
/// offscreen 680x600 `NSScrollView` + `NSTableView` (`TableTranscriptScene`,
/// below) and drives it the way the live pane does: asking it for heights and
/// cells, and feeding it updates. They pin render == measure for chat bubbles,
/// the per-block height cache, cell dispatch, the disclosure and prepend
/// anchors, tail-follow, cache bounds, the near-top signal, and the arithmetic
/// estimate's image term.
///
/// The visual harness that shares the scene — real-session oracle runs,
/// fixed-versus-unfixed proofs and PNG snapshots — is `TableTranscriptHarness`,
/// which compiles only with `-Xswiftc -DTBD_HARNESSES` (see `Tests/CLAUDE.md`).
@Suite("Table transcript pane (#129)")
@MainActor
struct TableTranscriptPaneTests {

    // MARK: - Per-block height cache (table reuse: no re-measure)

    /// A table-containing bubble's per-block heights are CACHED by the Coordinator
    /// when it sizes the row, so a scroll-reused `TranscriptBubbleCellView` lays
    /// its blocks out from the cache rather than re-allocating an
    /// `NSHostingController` to re-measure the table block on every dequeue. Cheap +
    /// headless. (#129)
    @Test("table bubble: per-block heights are cached and feed the reused cell (no re-measure)")
    func tableBlockHeightsCachedOnReuse() throws {
        let suiteName = "table-harness-blockcache-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = TableTranscriptScene.bubbleFixture()  // contains "b-table" (prose + GFM table + prose)
        let nodes = transcriptRenderNodes(from: items)
        let scene = TableTranscriptScene(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }

        // Size the bottom window — this measures the table bubble and caches its
        // per-block heights as a side effect.
        scene.coordinator.precomputeBottomWindow()

        let tableRow = try #require(nodes.firstIndex { $0.id == "b-table" })
        let node = nodes[tableRow]

        // The per-block height cache is POPULATED before any cell is built — so the
        // first `viewFor` (and every reuse after) is a cache hit, never a measure.
        let cached = try #require(
            scene.coordinator.cachedBlockHeights(for: node),
            "table bubble's per-block heights must be cached after sizing")
        #expect(cached.count >= 2, "a prose+table(+prose) bubble must cache a height per block")
        #expect(cached.allSatisfy { $0 > 0 }, "every cached block height must be positive")

        // The cell built via the reuse path (`viewFor`) renders at the cached
        // height: its realized drawn height equals `heightOfRow` within ~1pt, with
        // the blocks fed from the cache (no re-measure). render == measure.
        let measured = scene.coordinator.tableView(scene.tableView, heightOfRow: tableRow)
        let cell = try #require(
            scene.coordinator.tableView(scene.tableView, viewFor: nil, row: tableRow)
                as? TranscriptBubbleCellView,
            "table bubble row must dispatch to TranscriptBubbleCellView")
        cell.layoutSubtreeIfNeeded()
        #expect(abs(cell.realizedRowHeight - measured) <= 1.0,
                Comment(rawValue: "reused table bubble must render at the cached height "
                    + "(realized=\(cell.realizedRowHeight) measured=\(measured))"))

        // The cached per-block body height + chrome must equal the row height the
        // cache fed — proving the cache is the single source of truth for the row.
        let bodyHeight = MessageBlockMeasurer().blocksHeight(fromBlockHeights: cached)
        let expectedRowHeight = TranscriptBubbleGeometry.rowHeight(
            blocksHeight: bodyHeight, role: .assistant)
        #expect(abs(expectedRowHeight - measured) <= 0.5,
                Comment(rawValue: "cached block heights must sum (with chrome) to the row height "
                    + "(fromCache=\(expectedRowHeight) measured=\(measured))"))
    }

    // MARK: - Peer sender header

    /// The row-height invariant, extended to the one item kind that now draws a
    /// header: a peer bubble's `heightOfRow` must equal what the realized cell
    /// draws, and the SAME body as a user prompt must still measure exactly one
    /// header shorter. The second half is the regression the header can most
    /// easily cause — a user row that silently grew or shrank.
    ///
    /// Cheap + headless: it only asks the coordinator for heights and cells.
    @Test("peer bubble: heightOfRow == realized, and a user row is unchanged")
    func peerBubbleRowMeasureEqualsRender() throws {
        let suiteName = "table-harness-peer-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let repoID = UUID()
        let target = Worktree(
            id: UUID(), repoID: repoID, name: "Acme Deploy Watch",
            displayName: "Acme Deploy Watch", branch: "b",
            path: "/tmp/acme-deploy-watch", tmuxServer: "s")
        appState.worktrees = [repoID: [target]]

        // The SAME text on both rows, and `.user`/`.peer` share a body width, so
        // any difference between the two heights is the header and nothing else.
        let body = """
            Deploy finished on `acme-prod`. Two checks were skipped because their \
            upstream job had already gone green on the same commit, and the release \
            note draft is waiting in the queue for a human to read it.
            """
        let sender = PeerSender(
            name: "Acme Deploy Watch", from: "uds:/tmp/cc-socks/4242.sock",
            verified: true, pid: 4242)
        let items: [TranscriptItem] = [
            .userPrompt(id: "u1", text: body, timestamp: nil),
            .peerMessage(id: "p1", sender: sender, text: body,
                         deliveredPayload: nil, timestamp: nil)
        ]
        let nodes = transcriptRenderNodes(from: items)

        let scene = TableTranscriptScene(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        // Both rows must carry their EXACT height, not the estimate.
        scene.coordinator.precomputeBottomWindow()
        scene.tableView.reloadData()
        scene.settle()

        let userRow = try #require(nodes.firstIndex { $0.id == "u1" })
        let peerRow = try #require(nodes.firstIndex { $0.id == "p1" })

        // One row at a time: `viewFor` dequeues and RECONFIGURES a shared cell, so
        // the second call would reconfigure the first row's cell out from under us.
        let peerMeasured = scene.coordinator.tableView(scene.tableView, heightOfRow: peerRow)
        let peerCell = try #require(
            scene.coordinator.tableView(scene.tableView, viewFor: nil, row: peerRow)
                as? TranscriptBubbleCellView,
            "a peer message must dispatch to TranscriptBubbleCellView")
        peerCell.layoutSubtreeIfNeeded()
        let peerRealized = peerCell.realizedRowHeight
        #expect(abs(peerMeasured - peerRealized) <= 1.0,
                Comment(rawValue: "peer row must render at the height it was measured at "
                    + "(measured=\(peerMeasured) realized=\(peerRealized))"))

        let userMeasured = scene.coordinator.tableView(scene.tableView, heightOfRow: userRow)
        let userCell = try #require(
            scene.coordinator.tableView(scene.tableView, viewFor: nil, row: userRow)
                as? TranscriptBubbleCellView,
            "a user prompt must dispatch to TranscriptBubbleCellView")
        userCell.layoutSubtreeIfNeeded()
        let userRealized = userCell.realizedRowHeight
        #expect(abs(userMeasured - userRealized) <= 1.0,
                Comment(rawValue: "user row must render at the height it was measured at "
                    + "(measured=\(userMeasured) realized=\(userRealized))"))

        let header = TranscriptBubbleGeometry.headerHeight(for: .peer)
        #expect(header > 0)
        #expect(abs((peerMeasured - userMeasured) - header) <= 1.0,
                Comment(rawValue: "the same body must cost exactly one header more as a peer "
                    + "(peer=\(peerMeasured) user=\(userMeasured) header=\(header))"))
    }

    // MARK: - Native activity-cell dispatch

    /// Confirms `viewFor` routes each kind to the right cell type: a Bash
    /// tool-call row and the systemReminder row produce a native
    /// `ActivityRowCellView`, while the AskUserQuestion row stays SwiftUI-hosted
    /// (`TranscriptHostingCellView`). Cheap + headless: it only asks the
    /// coordinator for cells.
    @Test("native activity cells: Bash + systemReminder dispatch to ActivityRowCellView; AskUserQuestion stays hosted")
    func activityCellDispatch() {
        let suiteName = "table-harness-activity-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = TableTranscriptScene.allKindsFixture()
        let nodes = transcriptRenderNodes(from: items)
        let scene = TableTranscriptScene(items: items, appState: appState)
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

    // MARK: - Activity-group disclosure (anchoring, caches, tail-follow)

    /// Items shaped for the disclosure tests: `leadingBubbles` tall exchanges, then
    /// a run of `groupSize` Read tool calls (which `TranscriptPresentation` folds
    /// into ONE collapsible summary — the run needs ≥2 members to group at all),
    /// then `trailingBubbles` exchanges to flush the run and give the list a tail.
    private static func activityGroupFixture(
        leadingBubbles: Int,
        groupSize: Int,
        trailingBubbles: Int
    ) -> [TranscriptItem] {
        func exchange(_ tag: String, _ index: Int) -> [TranscriptItem] {
            [
                .userPrompt(
                    id: "\(tag)-u\(index)",
                    text: "Question \(index): walk me through this part of the pipeline in "
                        + "enough detail that the bubble wraps across several lines.",
                    timestamp: nil
                ),
                .assistantText(
                    id: "\(tag)-a\(index)",
                    text: """
                    Answer \(index): each upstream item becomes a render node cached by \
                    `(id, contentVersion, width)`, so a re-poll never rebuilds an unchanged \
                    row. This paragraph is deliberately long so the bubble has real height.

                    A second paragraph adds vertical extent so scroll offsets can land in \
                    the middle of a tall row.
                    """,
                    timestamp: nil,
                    usage: nil
                )
            ]
        }

        var items: [TranscriptItem] = []
        for i in 0..<leadingBubbles { items.append(contentsOf: exchange("lead", i)) }
        for i in 0..<groupSize {
            items.append(.toolCall(
                id: "grp-t\(i)",
                name: "Read",
                inputJSON: #"{"file_path":"/x/Sources/Part\#(i).swift"}"#,
                inputTruncatedTo: nil,
                result: ToolResult(text: "1\timport AppKit\n", truncatedTo: nil, isError: false),
                subagent: nil,
                timestamp: nil
            ))
        }
        for i in 0..<trailingBubbles { items.append(contentsOf: exchange("tail", i)) }
        return items
    }

    /// The summary node id `TranscriptPresentation.build` mints for the fixture's
    /// run of tool calls (first member's id + the group suffix).
    private static let fixtureGroupID = "grp-t0#activity-group"

    private static func groupNodes(_ items: [TranscriptItem], expanded: Bool) -> [TranscriptRenderNode] {
        TranscriptPresentation.build(
            items: items,
            expansionOverrides: [fixtureGroupID: expanded]
        ).nodes
    }

    /// Realizes every row once — as a user who scrolled the whole transcript would —
    /// so each carries an EXACT measured height rather than the cheap arithmetic
    /// estimate `heightOfRow` serves for unrealized rows.
    private func realizeAllRows(_ scene: TableTranscriptScene, count: Int) {
        for row in 0..<count {
            _ = scene.coordinator.tableView(scene.tableView, viewFor: nil, row: row)
        }
        scene.settle()
    }

    /// REGRESSION GUARD: expanding a collapsed work group must leave the clicked
    /// summary row exactly where it was on screen — only the content BELOW it may
    /// move. The reported bug scrolled the whole view up by the height of the
    /// revealed rows, because the toggle classifies as a `.rebuild` and the
    /// rebuild's tail-follow re-pinned the bottom.
    ///
    /// Run from the bottom of the transcript (the reported case, where tail-follow
    /// fires) and from a scrolled-up viewport (where the cache wipe's realize-time
    /// height corrections were the drift source).
    @Test("expanding a work group keeps the summary row anchored", arguments: [true, false])
    func expandingGroupKeepsSummaryAnchored(atBottom: Bool) async throws {
        let suiteName = "table-harness-group-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        // Shape of the fixture, both arms: more leading rows than the bottom-window
        // precompute measures, so the rows ABOVE the anchor are ones only the CACHE
        // can keep exact across the rebuild (a wipe sends them back to the arithmetic
        // estimate and the anchor moves with them). The tail is short when the
        // viewport must sit AT the bottom with the summary still on screen, and deep
        // when the viewport must be clear of the tail-follow threshold.
        let items = Self.activityGroupFixture(
            leadingBubbles: 25, groupSize: 5, trailingBubbles: atBottom ? 1 : 8)
        let collapsed = Self.groupNodes(items, expanded: false)
        let expanded = Self.groupNodes(items, expanded: true)
        #expect(expanded.count == collapsed.count + 5, "expansion must reveal the group's 5 rows")

        let scene = TableTranscriptScene(items: items, appState: appState, nodes: collapsed)
        defer { withExtendedLifetime(scene.coordinator) {} }

        // Prime exactly as production does, then let the column width settle (see
        // `prime(nodes:)`) — a width that moves mid-test sends the toggle down the
        // width-change branch, which wipes the caches for a reason that has nothing
        // to do with what this test guards.
        let primedWidth = scene.prime(nodes: collapsed)

        let summaryRow = try #require(collapsed.firstIndex { $0.id == Self.fixtureGroupID })
        let clip = scene.scrollView.contentView

        // Realize every row, so the "before" snapshot is entirely EXACT measurements.
        // Without this the rows above the anchor carry the arithmetic estimate, and a
        // later estimate→exact transition (from anything at all: a re-measure, a
        // width change, a different host font) could masquerade as anchor drift. The
        // guard below then reads exactly as written: heights that were exact before
        // the click must still be exact, and identical, after it.
        realizeAllRows(scene, count: collapsed.count)
        // One wrapped body line, from the theme's own font — the granularity the
        // arithmetic estimate can resolve at all.
        let oneRenderedLine = ceil(
            NSLayoutManager().defaultLineHeight(for: TranscriptTextTheme.chatBubble.bodyFont))
        var unpinnedAbove: [String] = []
        for row in 0..<summaryRow {
            let node = collapsed[row]
            guard let exact = scene.coordinator.cachedExactHeight(for: node) else {
                unpinnedAbove.append("row \(row) (\(node.id)): never measured")
                continue
            }
            // TIGHTER than "is it measured": the estimate these rows would have
            // carried has to be within one rendered LINE of the measurement, so the
            // realization above is a scaffold rather than the thing holding the
            // anchor up. Before this fixture's estimates were recalibrated they sat
            // 28 pt — nearly two lines — above the measurement, and every one of
            // those rows was free to jump when it realized.
            //
            // One line rather than one point, because that is the model's floor:
            // this fixture's assistant paragraph lays out to 2.0016 × the body
            // width at the harness's column, so which side of the wrap boundary it
            // lands on is not a thing arithmetic over a mean character advance can
            // see. `TranscriptEstimatorAccuracyTests` pins the per-kind budget and
            // the direction; this pins the shapes the disclosure fixture uses.
            let estimate = TableTranscriptView.Coordinator.estimate(for: node, width: primedWidth)
            if abs(estimate - exact) > oneRenderedLine {
                unpinnedAbove.append("row \(row) (\(node.id)): estimate \(estimate) vs measured \(exact)")
            }
        }
        #expect(unpinnedAbove.isEmpty,
                Comment(rawValue: "every row above the anchor must be exactly measured before the "
                    + "click AND carry an estimate within one rendered line "
                    + "(\(oneRenderedLine) pt) of that measurement, else an estimate→exact "
                    + "transition can masquerade as drift; offenders: "
                    + unpinnedAbove.prefix(5).joined(separator: "; ")))

        if atBottom {
            scene.coordinator.scrollToEnd(animated: false)
            scene.settle()
            #expect(scene.gapToBottom <= 120,
                    Comment(rawValue: "arm precondition: viewport must be within the tail-follow "
                        + "threshold (gap=\(scene.gapToBottom))"))
        } else {
            // Park the summary row ~200pt below the viewport top, so real rows sit
            // above it (any of which drifting would move the anchor).
            let target = max(0, scene.tableView.rect(ofRow: summaryRow).minY - 200)
            clip.scroll(to: NSPoint(x: 0, y: target))
            scene.scrollView.reflectScrolledClipView(clip)
            scene.settle()
            #expect(scene.gapToBottom > 120,
                    Comment(rawValue: "arm precondition: viewport must be clear of the tail-follow "
                        + "threshold (gap=\(scene.gapToBottom))"))
        }
        let visible = clip.documentVisibleRect
        let summaryRect = scene.tableView.rect(ofRow: summaryRow)
        #expect(visible.intersects(summaryRect), "the summary row must be on screen before the click")

        let offsetBefore = scene.screenOffset(ofRow: summaryRow)
        let rectsAboveBefore = (0..<summaryRow).map { scene.tableView.rect(ofRow: $0) }

        // The click: a new node array carrying the expanded group, with the toggle
        // token bumped exactly as `setActivityGroup` does.
        scene.coordinator.update(
            nodes: expanded, atBottom: .constant(true), activityToggleToken: 1, linkRoot: "")
        scene.tableView.layoutSubtreeIfNeeded()
        // The toggle must have gone through the `.rebuild` branch. If the column
        // width moved, `update` took the width-change branch instead — a legitimate
        // cache wipe for an unrelated reason — and everything below would be
        // measuring that, not the anchor.
        #expect(scene.tableView.bounds.width == primedWidth,
                Comment(rawValue: "the column width moved across the click "
                    + "(\(primedWidth) → \(scene.tableView.bounds.width)), so the toggle took the "
                    + "width-change branch rather than `.rebuild`"))
        // The FIRST frame after the click is what the user sees. Rows above the
        // anchor must already be laid out at their unchanged heights here — if the
        // rebuild dropped their cached exact heights they come back estimated, and
        // the anchor jumps now even though later realize-time corrections settle it
        // back.
        let offsetFirstFrame = scene.screenOffset(ofRow: summaryRow)
        #expect(abs(offsetFirstFrame - offsetBefore) <= 1.0,
                Comment(rawValue: "the clicked summary row moved in the first frame after the click: "
                    + "before=\(offsetBefore) firstFrame=\(offsetFirstFrame)"))

        // Give any deferred tail-follow its chance to run — without this the
        // assertion would pass against a scroll that simply never fired.
        await drainMainQueue()
        scene.settle()

        let offsetAfter = scene.screenOffset(ofRow: summaryRow)
        #expect(abs(offsetAfter - offsetBefore) <= 1.0,
                Comment(rawValue: "the clicked summary row moved on screen: "
                    + "before=\(offsetBefore) after=\(offsetAfter)"))

        let rectsAboveAfter = (0..<summaryRow).map { scene.tableView.rect(ofRow: $0) }
        var moved: [String] = []
        for (row, (before, after)) in zip(rectsAboveBefore, rectsAboveAfter).enumerated()
        where abs(before.origin.y - after.origin.y) > 0.5 || abs(before.height - after.height) > 0.5 {
            moved.append("row \(row): \(before) → \(after)")
        }
        #expect(moved.isEmpty,
                Comment(rawValue: "rows above the clicked row must keep identical rects: "
                    + moved.joined(separator: "; ")))
    }

    /// A mutable stand-in for the pane's live `AppState` worktree lookup: the
    /// root the resolver reads is a value that CHANGES under a pane that has
    /// already rendered.
    @MainActor
    private final class RootBox {
        var value: String
        init(_ value: String) { self.value = value }
    }

    /// The first `.link` URL over any prose block, or nil when the composed row
    /// carries no link at all.
    private static func firstLink(in blocks: [MessageBlock]) -> URL? {
        for block in blocks {
            guard case .prose(let string) = block else { continue }
            var found: URL?
            string.enumerateAttribute(
                .link, in: NSRange(location: 0, length: string.length), options: []
            ) { value, _, stop in
                if let url = value as? URL { found = url; stop.pointee = true }
            }
            if let found { return found }
        }
        return nil
    }

    /// REGRESSION GUARD, at the layer that actually decides: a worktree root
    /// arriving AFTER the pane composed its rows must relink those rows.
    ///
    /// Reading the root live inside the resolver closure is necessary but not
    /// sufficient — `composedBubbleBlocks` caches the fully-composed blocks,
    /// link ranges and all, keyed by `(id, contentVersion)`. The root is not
    /// part of that key, so on a cache HIT the resolver is never consulted and
    /// a row composed against the empty root of a restored panel stays plain
    /// text for the pane's whole life. Asserting the resolver closure alone
    /// (see `TranscriptLinkPaneRoutingTests`) cannot see that: it never reaches
    /// this cache.
    @Test("a worktree root arriving late relinks rows composed against the empty root")
    func lateWorktreeRootRelinksComposedRows() throws {
        let suiteName = "table-harness-linkroot-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("table-harness-linkroot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("docs/a.md"))
        defer { try? FileManager.default.removeItem(at: root) }

        // The pane's real resolver, over the pane's real memo, reading a root
        // that starts empty exactly as a restored panel's does.
        let box = RootBox("")
        let items: [TranscriptItem] = [
            .assistantText(id: "link-row", text: "see docs/a.md now", timestamp: nil, usage: nil)
        ]
        let scene = TableTranscriptScene(
            items: items,
            appState: appState,
            linkResolver: TranscriptLinkDestination.makeLinkResolver(
                worktreeRoot: { box.value },
                cache: TranscriptLinkResolverCache()
            )
        )
        defer { withExtendedLifetime(scene.coordinator) {} }

        let nodes = scene.coordinator.nodes
        scene.prime(nodes: nodes, linkRoot: box.value)
        realizeAllRows(scene, count: nodes.count)

        let node = try #require(nodes.first { if case .chatBubble = $0.kind { return true } else { return false } })
        guard case .chatBubble(let item) = node.kind else {
            Issue.record("fixture must project a chat-bubble row"); return
        }

        // Composed against the empty root: the relative token is plain text.
        #expect(Self.firstLink(in: scene.coordinator.composedBubbleBlocks(for: node, item: item)) == nil,
                "a relative token must not link while the worktree root is empty")

        // The worktree row lands, and the pane's next update carries the new root.
        box.value = root.path
        scene.coordinator.update(
            nodes: nodes, atBottom: .constant(true), activityToggleToken: 0, linkRoot: box.value)

        let linked = Self.firstLink(in: scene.coordinator.composedBubbleBlocks(for: node, item: item))
        #expect(linked?.path == root.path + "/docs/a.md",
                Comment(rawValue: "the row must recompose against the late root; got \(String(describing: linked))"))
    }

    /// FIX 2: the per-row caches are content-addressed by `(id, contentVersion,
    /// width)`, so a rebuild may PRUNE them but must not wipe them. Rows the user
    /// had already scrolled past stay EXACT across the rebuild rather than falling
    /// back to the arithmetic estimate (whose realize-time correction is what
    /// shifted rows underneath it).
    @Test("a rebuild keeps exact heights for rows whose content did not change")
    func rebuildKeepsContentAddressedHeights() throws {
        let suiteName = "table-harness-cachekeep-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        // More rows than the bottom-window precompute measures, so a wipe cannot be
        // masked by the post-rebuild `precomputeBottomWindow()`.
        let items = Self.activityGroupFixture(leadingBubbles: 30, groupSize: 4, trailingBubbles: 2)
        let collapsed = Self.groupNodes(items, expanded: false)
        #expect(collapsed.count > TableTranscriptView.Coordinator.bottomEagerWindow,
                "fixture must exceed the bottom-window precompute to be a real test")

        let scene = TableTranscriptScene(items: items, appState: appState, nodes: collapsed)
        defer { withExtendedLifetime(scene.coordinator) {} }
        scene.prime(nodes: collapsed)

        // Realize every row once — as a user scrolling the whole transcript would —
        // which measures each exactly and caches it.
        realizeAllRows(scene, count: collapsed.count)
        let uncachedBefore = collapsed
            .filter { scene.coordinator.cachedExactHeight(for: $0) == nil }
            .map(\.id)
        #expect(uncachedBefore.isEmpty,
                Comment(rawValue: "every realized row should have an exact cached height; missing: "
                    + uncachedBefore.prefix(5).joined(separator: ", ")))

        let expanded = Self.groupNodes(items, expanded: true)
        scene.coordinator.update(
            nodes: expanded, atBottom: .constant(true), activityToggleToken: 1, linkRoot: "")

        // Every unchanged row keeps its exact height. The summary node itself is
        // legitimately gone: `isExpanded` is part of its content, so the expanded
        // summary is a different `contentVersion` and the old entry is unreachable.
        let lost = collapsed
            .filter { $0.id != Self.fixtureGroupID }
            .filter { scene.coordinator.cachedExactHeight(for: $0) == nil }
            .map(\.id)
        #expect(lost.isEmpty,
                Comment(rawValue: "rebuild dropped \(lost.count)/\(collapsed.count - 1) exact heights "
                    + "for unchanged rows: \(lost.prefix(5).joined(separator: ", "))"))
        #expect(scene.coordinator.cachedExactHeight(for: collapsed[
            try #require(collapsed.firstIndex { $0.id == Self.fixtureGroupID })]) == nil,
                "the superseded summary node's entry must be pruned")
    }

    /// FIX 2's growth story: keeping caches across rebuilds must not let them grow
    /// without bound. Toggling a group open and shut repeatedly supersedes the
    /// summary node's `contentVersion` every time and removes/reinstates its member
    /// rows; the prune keeps the total pinned to the live row count.
    @Test("cache growth stays bounded across repeated expand/collapse cycles")
    func cacheGrowthIsBounded() throws {
        let suiteName = "table-harness-cachebound-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = Self.activityGroupFixture(leadingBubbles: 30, groupSize: 4, trailingBubbles: 2)
        let collapsed = Self.groupNodes(items, expanded: false)
        let expanded = Self.groupNodes(items, expanded: true)

        let scene = TableTranscriptScene(items: items, appState: appState, nodes: collapsed)
        defer { withExtendedLifetime(scene.coordinator) {} }
        scene.prime(nodes: collapsed)

        // Four caches, at most one entry per live row each.
        let ceiling = 4 * expanded.count
        var token = 0
        var peak = 0
        for cycle in 0..<12 {
            let nodes = cycle.isMultiple(of: 2) ? expanded : collapsed
            token += 1
            scene.coordinator.update(
                nodes: nodes, atBottom: .constant(true), activityToggleToken: token, linkRoot: "")
            // Realize every row so the caches are filled to their maximum each cycle.
            for row in 0..<nodes.count {
                _ = scene.coordinator.tableView(scene.tableView, viewFor: nil, row: row)
            }
            peak = max(peak, scene.coordinator.totalCachedEntryCount)
        }
        #expect(peak <= ceiling,
                Comment(rawValue: "cache entries grew past one per live row per cache "
                    + "(peak=\(peak) ceiling=\(ceiling))"))
    }

    /// FIX 1 must not over-reach: a genuine streaming append with the viewport at
    /// the bottom STILL follows the tail. Only a bumped toggle token suppresses it.
    @Test("a streaming append still follows the tail from the bottom")
    func streamingAppendStillFollowsTail() async throws {
        let suiteName = "table-harness-tailfollow-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = Self.activityGroupFixture(leadingBubbles: 8, groupSize: 5, trailingBubbles: 1)
        let collapsed = Self.groupNodes(items, expanded: false)

        let scene = TableTranscriptScene(items: items, appState: appState, nodes: collapsed)
        defer { withExtendedLifetime(scene.coordinator) {} }
        scene.prime(nodes: collapsed)
        scene.coordinator.scrollToEnd(animated: false)
        scene.settle()
        #expect(scene.gapToBottom <= 120, "precondition: the viewport starts at the bottom")

        // A new assistant message lands, as it does mid-stream. The toggle token
        // does NOT move — this is content the session produced.
        var grown = items
        grown.append(.assistantText(
            id: "stream-new",
            text: String(repeating: "A freshly streamed paragraph that wraps across the column. ", count: 12),
            timestamp: nil,
            usage: nil
        ))
        let appended = Self.groupNodes(grown, expanded: false)
        #expect(appended.count == collapsed.count + 1)

        scene.coordinator.update(
            nodes: appended, atBottom: .constant(true), activityToggleToken: 0, linkRoot: "")
        // The tail-follow is deferred to the next run-loop turn, by which point a
        // live app has laid the inserted row out; do that layout here so the
        // queued `scrollToEnd` sees the grown document rather than the old bottom.
        scene.tableView.layoutSubtreeIfNeeded()
        await drainMainQueue()
        scene.settle()

        #expect(scene.gapToBottom <= 2.0,
                Comment(rawValue: "a streaming append at the bottom must scroll to the new tail "
                    + "(gap=\(scene.gapToBottom))"))
    }

    // MARK: - Prepend anchor and near-top signal

    /// One assistant bubble whose length cycles with `n`, so rows differ in
    /// height and a mis-anchor by a row or two cannot land on an equal offset.
    private static func prependBubble(id: String, n: Int) -> TranscriptItem {
        let sentences = 2 + (n % 3) * 2
        return .assistantText(
            id: id,
            text: "Message \(n): "
                + String(repeating: "a remote record whose prose wraps across the column. ", count: sentences),
            timestamp: nil,
            usage: nil
        )
    }

    /// 50 records with stable (uuid-shaped) ids — more than the bottom-window
    /// precompute measures, so rows above the reader carry estimates — and the
    /// same 50 with 12 earlier records added at the front.
    private static func prependArrays() -> (before: [TranscriptRenderNode], after: [TranscriptRenderNode]) {
        let base = (0..<50).map { prependBubble(id: "rec-\($0)", n: $0) }
        let earlier = (0..<12).map { prependBubble(id: "early-\($0)", n: 100 + $0) }
        return (transcriptRenderNodes(from: base), transcriptRenderNodes(from: earlier + base))
    }

    @Test("a prepend keeps the top visible row where it was")
    func prependKeepsTopRowAnchored() async throws {
        let suiteName = "table-harness-prepend-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let (before, after) = Self.prependArrays()
        let scene = TableTranscriptScene(items: [], appState: appState, nodes: before)
        defer { withExtendedLifetime(scene.coordinator) {} }
        let primedWidth = scene.prime(nodes: before)

        scene.park(row: 20, below: 150)
        #expect(scene.gapToBottom > 120,
                Comment(rawValue: "precondition: the viewport must be clear of the tail-follow "
                    + "threshold (gap=\(scene.gapToBottom))"))
        let anchorID = before[20].id
        let offsetBefore = scene.screenOffset(ofRow: 20)

        scene.coordinator.update(
            nodes: after, atBottom: .constant(false), activityToggleToken: 0, linkRoot: "",
            prependToken: 1)
        #expect(scene.tableView.bounds.width == primedWidth,
                "the column width moved, so the prepend took the width-change branch")
        let index = try #require(after.firstIndex { $0.id == anchorID })
        #expect(index == 32)

        // The first frame after the prepend is what the reader sees.
        let offsetFirstFrame = scene.screenOffset(ofRow: index)
        #expect(abs(offsetFirstFrame - offsetBefore) <= 1.0,
                Comment(rawValue: "the anchor row moved in the first frame: "
                    + "before=\(offsetBefore) firstFrame=\(offsetFirstFrame)"))

        // Let AppKit lay the new rows out, run the deferred re-pin, and let any
        // estimated row above the anchor realize and correct its height.
        scene.tableView.layoutSubtreeIfNeeded()
        await drainMainQueue()
        scene.settle()

        let offsetAfter = scene.screenOffset(ofRow: index)
        #expect(abs(offsetAfter - offsetBefore) <= 1.0,
                Comment(rawValue: "the anchor row moved on screen across the prepend: "
                    + "before=\(offsetBefore) after=\(offsetAfter)"))
    }

    @Test("a prepend while at the bottom stays at the bottom")
    func prependAtBottomStaysAtBottom() async throws {
        let suiteName = "table-harness-prepend-bottom-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let (before, after) = Self.prependArrays()
        let scene = TableTranscriptScene(items: [], appState: appState, nodes: before)
        defer { withExtendedLifetime(scene.coordinator) {} }
        scene.prime(nodes: before)
        scene.coordinator.scrollToEnd(animated: false)
        scene.settle()
        #expect(scene.gapToBottom <= 120, "precondition: the viewport starts at the bottom")

        scene.coordinator.update(
            nodes: after, atBottom: .constant(true), activityToggleToken: 0, linkRoot: "",
            prependToken: 1)
        scene.tableView.layoutSubtreeIfNeeded()
        await drainMainQueue()
        scene.settle()

        #expect(scene.gapToBottom <= 120,
                Comment(rawValue: "a prepend at the bottom must leave the viewport at the bottom "
                    + "(gap=\(scene.gapToBottom))"))
    }

    @Test("with no stable id on screen, a prepend keeps the distance from the bottom")
    func prependWithoutStableIDKeepsBottomDistance() async throws {
        let suiteName = "table-harness-prepend-lineid-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        // Positional ids, as the parsers mint for records with no uuid: after the
        // prepend, `line-20` names a DIFFERENT record (the old one is `line-32`).
        let base = (0..<50).map { Self.prependBubble(id: "line-\($0)", n: $0) }
        let grown = (0..<62).map { index in
            Self.prependBubble(id: "line-\(index)", n: index < 12 ? 100 + index : index - 12)
        }
        let before = transcriptRenderNodes(from: base)
        let after = transcriptRenderNodes(from: grown)
        #expect(!TableTranscriptView.Coordinator.anchorID("line-20"))
        #expect(!TableTranscriptView.Coordinator.anchorID("tail-3"))
        #expect(TableTranscriptView.Coordinator.anchorID("rec-20"))

        let scene = TableTranscriptScene(items: [], appState: appState, nodes: before)
        defer { withExtendedLifetime(scene.coordinator) {} }
        scene.prime(nodes: before)
        scene.park(row: 20, below: 150)
        let gapBefore = scene.gapToBottom
        #expect(gapBefore > 120, "precondition: the viewport must be clear of the tail-follow threshold")
        let offsetBefore = scene.screenOffset(ofRow: 20)

        scene.coordinator.update(
            nodes: after, atBottom: .constant(false), activityToggleToken: 0, linkRoot: "",
            prependToken: 1)
        scene.tableView.layoutSubtreeIfNeeded()
        await drainMainQueue()
        scene.settle()

        let gapAfter = scene.gapToBottom
        #expect(abs(gapAfter - gapBefore) <= 1.0,
                Comment(rawValue: "the distance from the bottom moved: before=\(gapBefore) after=\(gapAfter)"))
        // The record the reader was looking at (now row 32) stays put too.
        let offsetAfter = scene.screenOffset(ofRow: 32)
        #expect(abs(offsetAfter - offsetBefore) <= 1.0,
                Comment(rawValue: "the record on screen moved: before=\(offsetBefore) after=\(offsetAfter)"))
    }

    /// Pins the gate: local panes and Session History never bump the token, so a
    /// rebuild that happens to look like a prepend keeps today's behavior — the
    /// clip stays at its document offset and the old rows move down by the
    /// height inserted above them.
    @Test("a rebuild without a prepend token behaves as before")
    func rebuildWithoutPrependTokenUnchanged() async throws {
        let suiteName = "table-harness-prepend-gate-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let (before, after) = Self.prependArrays()
        let scene = TableTranscriptScene(items: [], appState: appState, nodes: before)
        defer { withExtendedLifetime(scene.coordinator) {} }
        scene.prime(nodes: before)
        scene.park(row: 20, below: 150)
        let offsetBefore = scene.screenOffset(ofRow: 20)
        let originBefore = scene.scrollView.contentView.bounds.origin.y

        scene.coordinator.update(
            nodes: after, atBottom: .constant(false), activityToggleToken: 0, linkRoot: "")
        #expect(scene.coordinator.pendingPrependAnchor == nil)
        // Read before any realize-time correction can move rows above the clip.
        #expect(abs(scene.scrollView.contentView.bounds.origin.y - originBefore) <= 0.5,
                "without the token the clip must keep its document offset")
        scene.tableView.layoutSubtreeIfNeeded()
        await drainMainQueue()
        scene.settle()

        let inserted = scene.tableView.rect(ofRow: 12).minY
        #expect(inserted > 300, Comment(rawValue: "precondition: 12 rows inserted (\(inserted) pt)"))
        let moved = scene.screenOffset(ofRow: 32) - offsetBefore
        #expect(moved >= inserted * 0.5,
                Comment(rawValue: "without the token the row must move down by about the inserted "
                    + "height (moved=\(moved) inserted=\(inserted))"))
    }

    /// A held prepend anchor keeps the reader's place until the reader moves
    /// it. A reader scroll is a move of the clip's origin the coordinator did
    /// not make; a change to the viewport's size leaves the origin, and the
    /// reader's place, where they were.
    @Test("a reader scroll releases a held prepend anchor, and a viewport resize does not")
    func readerScrollReleasesPrependAnchor() async throws {
        let suiteName = "table-harness-prepend-release-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let (before, after) = Self.prependArrays()
        let scene = TableTranscriptScene(items: [], appState: appState, nodes: before)
        defer { withExtendedLifetime(scene.coordinator) {} }
        scene.prime(nodes: before)
        scene.coordinator.startObservingScroll()
        scene.park(row: 20, below: 150)
        try #require(scene.gapToBottom > 120,
                     Comment(rawValue: "precondition: the viewport must be clear of the tail-follow "
                         + "threshold (gap=\(scene.gapToBottom))"))
        // The prepend anchors the first visible row with a stable id. Every
        // id here is stable, and row 20 is parked 150pt down, so that is a
        // row above it, read the way `capturePrependAnchor` reads it.
        let clip = scene.scrollView.contentView
        let firstVisible = scene.tableView.rows(in: clip.documentVisibleRect).location
        try #require(firstVisible != NSNotFound && firstVisible < 20,
                     Comment(rawValue: "precondition: rows above row 20 are on screen (first \(firstVisible))"))
        let anchorID = before[firstVisible].id

        scene.coordinator.update(
            nodes: after, atBottom: .constant(false), activityToggleToken: 0, linkRoot: "",
            prependToken: 1)
        scene.tableView.layoutSubtreeIfNeeded()
        await drainMainQueue()
        scene.settle()
        let anchor = try #require(scene.coordinator.pendingPrependAnchor,
                                  Comment(rawValue: "precondition: the prepend still holds its anchor once its rows "
                                      + "settled; \(scene.heldReaderMoveNote)"))
        try #require(anchor.id == anchorID,
                     Comment(rawValue: "precondition: the prepend anchored the first visible row, \(anchorID); "
                         + scene.heldReaderMoveNote))

        let origin = clip.bounds.minY
        scene.scrollView.frame = NSRect(
            x: 0, y: 0, width: TableTranscriptScene.width, height: TableTranscriptScene.viewportHeight - 100)
        scene.settle()
        try #require(clip.bounds.height < TableTranscriptScene.viewportHeight - 50,
                     Comment(rawValue: "precondition: the viewport got shorter (\(clip.bounds.height) pt)"))
        try #require(abs(clip.bounds.minY - origin) <= 0.5,
                     Comment(rawValue: "precondition: the origin stayed (\(origin) → \(clip.bounds.minY)); "
                         + scene.heldReaderMoveNote))
        // Whether or not the resize itself posted one, the observer hears a
        // bounds change against the new size, as it would from AppKit.
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
        #expect(scene.coordinator.pendingPrependAnchor == anchor,
                Comment(rawValue: "a viewport resize released the prepend anchor; \(scene.heldReaderMoveNote)"))

        scene.scroll(toY: clip.bounds.minY + 120)
        #expect(scene.coordinator.pendingPrependAnchor == nil, "a reader scroll left the prepend anchor held")
    }

    @Test("near-top reports transitions only")
    func nearTopReportsTransitions() throws {
        let suiteName = "table-harness-neartop-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let (before, _) = Self.prependArrays()
        let scene = TableTranscriptScene(items: [], appState: appState, nodes: before)
        defer { withExtendedLifetime(scene.coordinator) {} }
        scene.prime(nodes: before)
        scene.coordinator.startObservingScroll()
        scene.coordinator.scrollToEnd(animated: false)
        scene.settle()

        final class Recorder { var values: [Bool] = [] }
        let recorder = Recorder()
        scene.coordinator.onNearTop = { recorder.values.append($0) }

        scene.scroll(toY: 0)
        #expect(recorder.values == [true])
        scene.scroll(toY: scene.tableView.rect(ofRow: 3).minY + 1)
        #expect(recorder.values == [true], "row 3 at the top is still near the top")
        scene.scroll(toY: .greatestFiniteMagnitude)
        #expect(recorder.values == [true, false])
        scene.scroll(toY: 0)
        #expect(recorder.values == [true, false, true])
        #expect(TableTranscriptView.Coordinator.nearTopRowThreshold == 5)
    }

    // MARK: - Image-attachment height estimate

    /// FIX 3: the arithmetic estimate must include an image term. The exact path
    /// lays an attachment out at up to 200pt from a synchronous header probe, so
    /// an estimate that only counted the marker's characters undershot by ~180pt —
    /// a correction that big, applied when the row realizes, drags every row below
    /// it.
    @Test("an image attachment is estimated close to its exact measured height")
    func imageAttachmentEstimateMatchesExact() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-image-estimate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let imagePath = dir.appendingPathComponent("shot.png").path
        try Self.writePNG(width: 400, height: 300, to: imagePath)

        let item = TranscriptItem.userPrompt(
            id: "img-1",
            text: "Here is the screenshot.\n\n[Image: source: \(imagePath)]",
            timestamp: nil
        )
        let node = TranscriptRenderNode(id: "img-1", kind: .chatBubble(item), badgeUsage: nil)

        let estimate = TableTranscriptView.Coordinator.estimate(for: node, width: TableTranscriptScene.width)
        let exact = TableTranscriptScene.oracleHeight(for: node)

        // The image alone is 150pt tall here (a 400x300 source contained in the
        // 200pt square), so a missing image term shows up as a ~150pt undershoot.
        #expect(exact > 150, Comment(rawValue: "fixture must actually carry a laid-out image (exact=\(exact))"))
        #expect(abs(estimate - exact) <= 20,
                Comment(rawValue: "image row estimate is far from the exact height: "
                    + "estimate=\(estimate) exact=\(exact)"))
    }

    /// A marker-free bubble's estimate is unchanged by the image term — the split
    /// fast path returns one text segment and the arithmetic is as before.
    @Test("a bubble with no attachment still estimates from its prose alone")
    func plainBubbleEstimateUnaffected() {
        let item = TranscriptItem.assistantText(
            id: "plain-1",
            text: "A plain paragraph with no attachment marker, long enough to wrap "
                + "across more than one line of the column.",
            timestamp: nil,
            usage: nil
        )
        let node = TranscriptRenderNode(id: "plain-1", kind: .chatBubble(item), badgeUsage: nil)
        let estimate = TableTranscriptView.Coordinator.estimate(for: node, width: TableTranscriptScene.width)
        let exact = TableTranscriptScene.oracleHeight(for: node)
        #expect(abs(estimate - exact) <= 20,
                Comment(rawValue: "plain bubble estimate drifted: estimate=\(estimate) exact=\(exact)"))
    }

    /// Writes a solid opaque PNG so `TranscriptImageService`'s header probe reads
    /// real pixel dimensions.
    private static func writePNG(width: Int, height: Int, to path: String) throws {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let png = rep.representation(using: .png, properties: [:]) else {
            throw FixtureError.couldNotMakePNG
        }
        try png.write(to: URL(fileURLWithPath: path))
    }

    private enum FixtureError: Error {
        case couldNotMakePNG
    }
}

// MARK: - Scene

/// An offscreen 680x600 scroll view + table wired to the production
/// `TableTranscriptView.Coordinator`, mirroring `makeNSView`'s setup. Shared by
/// `TableTranscriptPaneTests` and the env-gated `TableTranscriptHarness`.
@MainActor
struct TableTranscriptScene {
    static let width: CGFloat = 680
    static let viewportHeight: CGFloat = 600

    let scrollView: NSScrollView
    let tableView: NSTableView
    let coordinator: TableTranscriptView.Coordinator
    let window: NSWindow

    /// Builds the scene over `items`.
    ///
    /// `nodes` overrides the render nodes the coordinator starts on — used by the
    /// activity-group tests, whose lists come from `TranscriptPresentation.build`
    /// (grouped/collapsed) rather than the raw per-item projection.
    /// `makeCoordinator` substitutes a coordinator subclass; the harness uses it
    /// to count calls and to reproduce the pre-fix sizing.
    init(
        items: [TranscriptItem],
        appState: AppState,
        nodes overrideNodes: [TranscriptRenderNode]? = nil,
        linkResolver: TranscriptPathResolver? = nil,
        makeCoordinator: (@MainActor (TranscriptCardContext) -> TableTranscriptView.Coordinator)? = nil
    ) {
        let context = TranscriptCardContext(
            terminalID: nil,
            openTranscriptOverlay: { _ in },
            appState: appState,
            linkResolver: linkResolver,
            onLinkClicked: nil
        )
        let coordinator: TableTranscriptView.Coordinator
        if let makeCoordinator {
            coordinator = makeCoordinator(context)
        } else {
            coordinator = TableTranscriptView.Coordinator(context: context)
        }

        // AppKit's own row-height estimation is off for this whole process, as
        // the app turns it off at launch: the `TestProcessDefaults` target
        // registers the opt-out when the test bundle loads. Registering it here
        // would come too late, because AppKit reads it once per process and
        // another suite may have built a table first. `prime(nodes:)` and
        // `requireDelegateRowHeights()` say so if it is ever on.
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
        // PIN THE SCROLLER GEOMETRY. `NSScroller.preferredScrollerStyle` follows the
        // host's "Show scroll bars" setting and whether a scroll-capable pointing
        // device is attached, so an unpinned scroll view is 680pt wide on a developer
        // box with overlay scrollers and 663pt on a runner with legacy ones — and
        // every measured row height is keyed by that width. Pin the LEGACY,
        // autohiding shape (the moving one: the scroller claims its 17pt only once
        // the document outgrows the viewport, i.e. after the first `reloadData`) so
        // every environment exercises the same geometry AND the same mid-setup width
        // change. `prime(nodes:)` is what absorbs that change.
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        coordinator.tableView = tableView
        coordinator.scrollView = scrollView

        let nodes = overrideNodes ?? transcriptRenderNodes(from: items)
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

        self.scrollView = scrollView
        self.tableView = tableView
        self.coordinator = coordinator
        self.window = window
    }

    // MARK: Settling

    /// Turns of the run loop the table's geometry has to hold still across
    /// before `settle()` calls it settled.
    private static let settledTurns = 3

    /// Drives the table to a layout fixed point.
    ///
    /// Realizing a row measures it exactly, and a measurement that differs from
    /// the estimate the row was laid out at calls `noteHeightOfRows`, which takes
    /// effect only on the NEXT layout pass — which may realize more rows, which
    /// may correct again. Settling is that loop run until it stops: one bounded
    /// turn of the run loop, for whatever AppKit schedules there, a layout pass,
    /// and a comparison, until the table's width, document height and every row
    /// height have held across `settledTurns` consecutive turns. The width is in
    /// the comparison because `prime(nodes:)` waits on it: the autohiding scroller
    /// claims its 17pt only after the first reload outgrows the viewport.
    ///
    /// Bounded by turns, never by elapsed time: a table that never settles
    /// spends `OffscreenHostDefaults.maxPumps` turns and returns, and the
    /// caller's own geometry assertions say what is wrong.
    ///
    /// Synchronous on purpose. It never suspends, so a block the coordinator
    /// deferred with `DispatchQueue.main.async` — the tail-follow
    /// `scrollToEnd`, the prepend re-pin — stays queued until a test hands the
    /// main actor back (`drainMainQueue()`); a nested run loop cannot run it
    /// (see `Tests/CLAUDE.md`, "`@MainActor` tests: suspend to drain, never
    /// pump").
    func settle() {
        var previous = geometry
        var unchangedTurns = 0
        for _ in 0..<OffscreenHostDefaults.maxPumps {
            RunLoopPump.turn()
            tableView.layoutSubtreeIfNeeded()
            let current = geometry
            if current == previous {
                unchangedTurns += 1
                if unchangedTurns >= Self.settledTurns { return }
            } else {
                unchangedTurns = 0
                previous = current
            }
        }
    }

    /// What `settle()` waits on.
    private struct Geometry: Equatable {
        let width: CGFloat
        let documentHeight: CGFloat
        let rowHeights: [CGFloat]
    }

    private var geometry: Geometry {
        Geometry(
            width: tableView.bounds.width,
            documentHeight: tableView.frame.height,
            rowHeights: (0..<tableView.numberOfRows).map { tableView.rect(ofRow: $0).height })
    }

    // MARK: Oracle

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
    static func oracleHeight(for node: TranscriptRenderNode) -> CGFloat {
        // Chat bubbles render as a vertical stack of typed blocks (prose on
        // TextKit-1, tables as native grid views) inside one bubble — NOT the
        // SwiftUI SelectableTranscriptRow. The ground truth for those rows is the
        // per-block measurement: an INDEPENDENT `MessageBlockMeasurer` over the
        // composed blocks at the SAME body width, plus inter-block spacing and the
        // fixed chrome. (Render==measure for the realized bubble cell is verified
        // separately, by `TableTranscriptPaneTests` and `TableTranscriptHarness`.)
        // Every other kind keeps the width-honouring SwiftUI hosting oracle.
        if case .chatBubble(let item) = node.kind {
            let blocks = TranscriptBubbleGeometry.composedBlocks(
                for: item, badgeUsage: node.badgeUsage, linkResolver: nil)
            let bodyWidth = TranscriptBubbleGeometry.bodyWidth(
                columnWidth: Self.width, role: TranscriptBubbleGeometry.role(for: item))
            let blocksHeight = MessageBlockMeasurer().blocksHeight(blocks, bodyWidth: bodyWidth)
            return TranscriptBubbleGeometry.rowHeight(
                blocksHeight: blocksHeight, role: TranscriptBubbleGeometry.role(for: item))
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

    // MARK: Fixtures

    /// A short session that produces one render node of each kind the live pane
    /// must size correctly: user + assistant chat bubbles, a Bash and a Read
    /// tool card, an AskUserQuestion card, an assistant message containing a GFM
    /// table, a systemReminder, and a Task tool whose subagent yields a
    /// `subagentSummary` row.
    static func allKindsFixture() -> [TranscriptItem] {
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

    /// A short session exercising the attributed bubble cell path: a very long
    /// (>5000pt) assistant message, a message carrying a token badge, a bubble
    /// containing a GFM table, a code-block bubble, and a short user message.
    static func bubbleFixture() -> [TranscriptItem] {
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
}
