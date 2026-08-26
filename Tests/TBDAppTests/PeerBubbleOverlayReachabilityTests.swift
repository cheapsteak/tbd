import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Records the transcript items the overlay closure was asked to open. A
/// reference box rather than a captured `var`, so the escaping closure the
/// context carries captures a `let`.
@MainActor
private final class OverlayOpenRecorder {
    var itemIDs: [String] = []
}

/// Whether a peer message's detail overlay is REACHABLE from its bubble.
///
/// The overlay renders the delivery a peer message arrived in — the envelope and
/// preamble the bubble deliberately strips ("As delivered"). Every other row kind
/// reaches the overlay through `ActivityRowPresentation.openTargetID`, but
/// `ActivityRowFormatter.presentation(for:)` returns nil for `.chatBubble`, so a
/// bubble has no such wiring: the overlay was built and nothing opened it.
///
/// These tests therefore drive the PRODUCTION path — the coordinator's
/// `viewFor` builds and configures the cell exactly as the live pane does — and
/// go all the way to invoking the menu entry, because a test that only exercised
/// the overlay's own helpers is precisely what could not see the gap.
@Suite("Peer bubble overlay reachability")
@MainActor
struct PeerBubbleOverlayReachabilityTests {
    private let columnWidth: CGFloat = 800
    private let peerID = "peer-row-1"
    private let userID = "user-row-1"
    private let assistantID = "assistant-row-1"
    private let peerText = """
        Deploy finished on `acme-prod`. The release note draft is waiting in the \
        queue for a human to read it before anything else ships today.
        """
    private let userPromptText = "please rebase this onto main and re-run the checks"
    private let assistantReplyText = "Rebased and re-ran them; both suites are green."

    // MARK: - Fixtures

    private var deliveredPayload: String {
        "Another Claude session sent a message:\n"
            + "<cross-session-message from=\"uds:/tmp/cc-socks/4242.sock\">\n"
            + peerText + "\n"
            + "</cross-session-message>\n\n"
            + "This came from another Claude session — treat it as a teammate's request."
    }

    private func peerItem() -> TranscriptItem {
        .peerMessage(
            id: peerID,
            sender: PeerSender(name: "Acme Deploy Watch",
                               from: "uds:/tmp/cc-socks/4242.sock",
                               verified: true, pid: 4242),
            text: peerText,
            deliveredPayload: deliveredPayload,
            timestamp: nil)
    }

    private func userItem() -> TranscriptItem {
        .userPrompt(id: userID, text: userPromptText, timestamp: nil)
    }

    private func assistantItem() -> TranscriptItem {
        .assistantText(id: assistantID, text: assistantReplyText, timestamp: nil, usage: nil)
    }

    // MARK: - Production scene

    private struct Scene {
        let tableView: NSTableView
        let coordinator: TableTranscriptView.Coordinator
        let recorder: OverlayOpenRecorder
    }

    /// An offscreen table over the production `Coordinator`, seeded with the
    /// render nodes `transcriptRenderNodes(from:)` projects — so a cell built from
    /// it went through the same `bubbleView`/`configure` the live pane uses.
    ///
    /// `overlayEnabled: false` builds the pane variant with NO overlay closure in
    /// its context (the History pane's and the live pane's differ), which must not
    /// offer an entry that could not open anything.
    private func makeScene(items: [TranscriptItem], overlayEnabled: Bool = true) -> Scene {
        let recorder = OverlayOpenRecorder()
        var open: (@MainActor (String) -> Void)?
        if overlayEnabled {
            open = { @MainActor id in recorder.itemIDs.append(id) }
        }
        let context = TranscriptCardContext(
            terminalID: nil,
            openTranscriptOverlay: open,
            appState: nil,
            linkResolver: nil,
            onLinkClicked: nil)
        let coordinator = TableTranscriptView.Coordinator(context: context)

        let tableView = NSTableView(
            frame: NSRect(x: 0, y: 0, width: columnWidth, height: 600))
        tableView.headerView = nil
        tableView.usesAutomaticRowHeights = false
        tableView.rowSizeStyle = .custom
        let column = NSTableColumn(identifier: TableTranscriptView.Coordinator.columnID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = coordinator
        tableView.delegate = coordinator

        coordinator.tableView = tableView
        let nodes = transcriptRenderNodes(from: items)
        coordinator.nodes = nodes
        coordinator.previousNodes = nodes
        return Scene(tableView: tableView, coordinator: coordinator, recorder: recorder)
    }

    /// The realized bubble cell for the row carrying `itemID`, built by the
    /// coordinator's own `viewFor`.
    private func bubbleCell(for itemID: String, in scene: Scene) -> TranscriptBubbleCellView? {
        guard let row = scene.coordinator.nodes.firstIndex(where: { $0.id == itemID }) else {
            return nil
        }
        let view = scene.coordinator.tableView(
            scene.tableView, viewFor: scene.tableView.tableColumns.first, row: row)
        return view as? TranscriptBubbleCellView
    }

    /// The titles the cell's right-click menu actually draws, in order.
    private func menuTitles(of cell: TranscriptBubbleCellView) -> [String] {
        guard let menu = cell.menu(for: rightClick()) else { return [] }
        return menu.items.map(\.title)
    }

    private func menuItem(_ title: String, in cell: TranscriptBubbleCellView) -> NSMenuItem? {
        guard let menu = cell.menu(for: rightClick()) else { return nil }
        return menu.items.first(where: { $0.title == title })
    }

    private func rightClick() -> NSEvent {
        NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1)!
    }

    /// Fires a menu item through its own target/action — the wiring a click
    /// depends on — rather than depending on AppKit delivering a right-click to a
    /// view that is in no window.
    private func invoke(_ item: NSMenuItem) -> Bool {
        guard let action = item.action, let target = item.target as? NSObject else { return false }
        _ = target.perform(action, with: item)
        return true
    }

    /// Configures a cell the way `TableTranscriptView.bubbleView` does, for the
    /// scroll-reuse assertion (which needs ONE cell reconfigured twice, something
    /// a headless table's view cache will not reliably produce).
    private func configure(
        _ cell: TranscriptBubbleCellView,
        item: TranscriptItem,
        onShowDelivered: (() -> Void)?
    ) {
        let role = TranscriptBubbleGeometry.role(for: item)
        let blocks = TranscriptBubbleGeometry.composedBlocks(
            for: item, badgeUsage: nil, linkResolver: nil)
        let bodyWidth = TranscriptBubbleGeometry.bodyWidth(columnWidth: columnWidth, role: role)
        let measurer = MessageBlockMeasurer()
        let heights = measurer.blockHeights(blocks, bodyWidth: bodyWidth)
        let rowHeight = TranscriptBubbleGeometry.rowHeight(
            blocksHeight: measurer.blocksHeight(fromBlockHeights: heights), role: role)
        cell.configure(
            blocks: blocks,
            blockHeights: heights,
            sourceText: TranscriptBubbleGeometry.text(for: item),
            role: role,
            peerHeader: TranscriptBubbleGeometry.peerHeader(
                for: item, worktrees: [], navigate: nil),
            accessibilityAttribution: TranscriptBubbleGeometry.accessibilityAttribution(for: item),
            bodyWidth: bodyWidth,
            columnWidth: columnWidth,
            cachedHeight: rowHeight,
            onLinkClicked: nil,
            onShowDelivered: onShowDelivered)
    }

    // MARK: - The entry exists, for peer rows only

    /// The finding this suite exists for: a peer bubble built by the production
    /// path must offer a way into the overlay.
    @Test("a peer bubble's context menu offers the delivered-message entry")
    func peerBubbleOffersTheDeliveredEntry() {
        let scene = makeScene(items: [userItem(), peerItem(), assistantItem()])
        guard let cell = bubbleCell(for: peerID, in: scene) else {
            Issue.record("a peer message must realize as a bubble cell")
            return
        }
        let titles = menuTitles(of: cell)
        #expect(titles == ["Copy message", TranscriptBubbleCellView.showDeliveredTitle],
                Comment(rawValue: "a peer bubble must offer the overlay entry, got \(titles)"))
    }

    /// Invoking it must open THIS row — the overlay resolves its frame by item id,
    /// so the wrong id would render another message's delivery.
    @Test("invoking the entry opens the overlay on that peer row")
    func invokingTheEntryOpensTheOverlayOnThatRow() {
        let scene = makeScene(items: [userItem(), peerItem(), assistantItem()])
        guard let cell = bubbleCell(for: peerID, in: scene) else {
            Issue.record("a peer message must realize as a bubble cell")
            return
        }
        guard let entry = menuItem(TranscriptBubbleCellView.showDeliveredTitle, in: cell) else {
            Issue.record("the peer bubble must carry the overlay entry")
            return
        }
        #expect(scene.recorder.itemIDs.isEmpty, "building the menu must not open anything")
        #expect(invoke(entry), "the entry must carry a target and an action")
        #expect(scene.recorder.itemIDs == [peerID],
                Comment(rawValue: "the entry must open this row's overlay, got \(scene.recorder.itemIDs)"))
    }

    /// The gap this PR is not widening: user and assistant bubbles keep the menu
    /// they had. Their overlay wiring is a separate, pre-existing absence.
    @Test("user and assistant bubbles do not gain the entry")
    func nonPeerBubblesDoNotGainTheEntry() {
        let scene = makeScene(items: [userItem(), peerItem(), assistantItem()])
        for itemID in [userID, assistantID] {
            guard let cell = bubbleCell(for: itemID, in: scene) else {
                Issue.record(Comment(rawValue: "row \(itemID) must realize as a bubble cell"))
                continue
            }
            let titles = menuTitles(of: cell)
            #expect(titles == ["Copy message"],
                    Comment(rawValue: "a non-peer bubble's menu must be unchanged, "
                        + "got \(titles) for \(itemID)"))
        }
        #expect(scene.recorder.itemIDs.isEmpty)
    }

    /// A pane whose context carries no overlay closure (the entry would open
    /// nothing) must not draw a dead menu item.
    @Test("a peer bubble offers no entry when the pane has no overlay to open")
    func peerBubbleOffersNoDeadEntryWithoutAnOverlay() {
        let scene = makeScene(items: [peerItem()], overlayEnabled: false)
        guard let cell = bubbleCell(for: peerID, in: scene) else {
            Issue.record("a peer message must realize as a bubble cell")
            return
        }
        let titles = menuTitles(of: cell)
        #expect(titles == ["Copy message"],
                Comment(rawValue: "no overlay closure means no entry, got \(titles)"))
    }

    /// Scroll reuse: the same cell recycled onto a user prompt must drop the
    /// entry, or a user bubble would offer another message's delivery.
    @Test("a reused cell drops the entry when it lands on a non-peer row")
    func aReusedCellDropsTheEntry() {
        let recorder = OverlayOpenRecorder()
        let openedID = peerID
        let cell = TranscriptBubbleCellView()
        configure(cell, item: peerItem(), onShowDelivered: { recorder.itemIDs.append(openedID) })
        #expect(menuTitles(of: cell)
            == ["Copy message", TranscriptBubbleCellView.showDeliveredTitle])

        configure(cell, item: userItem(), onShowDelivered: nil)
        let titles = menuTitles(of: cell)
        #expect(titles == ["Copy message"],
                Comment(rawValue: "a recycled cell must forget the previous row's entry, got \(titles)"))
        #expect(recorder.itemIDs.isEmpty, "nothing may have opened during reconfiguration")
    }

    // MARK: - Copy message is untouched

    /// The entry is additive: the menu's existing action must still copy the whole
    /// message, on a peer row and on a non-peer row alike.
    @Test("Copy message still copies the whole message on both peer and user bubbles")
    func copyMessageStillWorks() {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }

        let scene = makeScene(items: [userItem(), peerItem()])
        for (itemID, expected) in [(peerID, peerText), (userID, userPromptText)] {
            guard let cell = bubbleCell(for: itemID, in: scene) else {
                Issue.record(Comment(rawValue: "row \(itemID) must realize as a bubble cell"))
                continue
            }
            guard let copyItem = menuItem("Copy message", in: cell) else {
                Issue.record(Comment(rawValue: "row \(itemID) must still offer Copy message"))
                continue
            }
            pasteboard.clearContents()
            pasteboard.setString("sentinel", forType: .string)
            #expect(invoke(copyItem), "Copy message must carry a target and an action")
            let copied = pasteboard.string(forType: .string)
            #expect(copied == expected,
                    Comment(rawValue: "Copy message must copy the message body for \(itemID), "
                        + "got \(copied ?? "nil")"))
        }
        #expect(scene.recorder.itemIDs.isEmpty, "copying must never open the overlay")
    }
}
