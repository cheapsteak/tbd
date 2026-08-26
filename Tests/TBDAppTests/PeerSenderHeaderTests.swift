import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// The sender header a peer bubble draws above its body — and the height math it
/// changes.
///
/// The height assertions are the load-bearing half. `TranscriptBubbleGeometry`'s
/// measurer and its renderer must agree or rows drift (the issue #129 failure
/// mode), so the header enters `rowHeight` and the realized cell together, for
/// PEER rows only. The user/assistant regression guard is the failure this change
/// can most easily cause.
/// Records the worktrees a header's navigation closure was asked to open. A
/// reference box rather than a captured `var`, so the escaping closure captures a
/// `let`.
@MainActor
private final class NavigationRecorder {
    var ids: [UUID] = []
}

@Suite("Peer sender header")
@MainActor
struct PeerSenderHeaderTests {
    private let columnWidth: CGFloat = 800
    /// Long enough to wrap at 800pt, so a header's line height cannot hide inside
    /// a rounding slack in a one-line bubble.
    private let body = """
        Deploy finished on `acme-prod`. Two checks were skipped because their \
        upstream job had already gone green on the same commit, and the release \
        note draft is waiting in the queue for a human to read it.
        """

    // MARK: - Fixtures

    private func worktree(_ displayName: String, id: UUID = UUID()) -> Worktree {
        Worktree(id: id, repoID: UUID(), name: displayName,
                 displayName: displayName, branch: "b",
                 path: "/tmp/\(displayName)", tmuxServer: "s")
    }

    private func verifiedSender(_ name: String) -> PeerSender {
        PeerSender(name: name, from: "uds:/tmp/cc-socks/4242.sock", verified: true, pid: 4242)
    }

    private func assertedSender(_ from: String) -> PeerSender {
        PeerSender(name: nil, from: from, verified: false, pid: nil)
    }

    private func peerItem(_ sender: PeerSender) -> TranscriptItem {
        .peerMessage(id: "p1", sender: sender, text: body,
                     deliveredPayload: nil, timestamp: nil)
    }

    /// Measures a bubble the way the table does, configures a live cell from the
    /// SAME blocks at the SAME body width, and hands back both numbers plus the
    /// cell — i.e. the measure/render pair the row-height invariant is about.
    private func measureAndRender(
        item: TranscriptItem,
        role: TranscriptBubbleGeometry.Role,
        peerHeader: TranscriptPeerHeader?
    ) -> (reserved: CGFloat, cell: TranscriptBubbleCellView) {
        let blocks = TranscriptBubbleGeometry.composedBlocks(
            for: item, badgeUsage: nil, linkResolver: nil)
        let bodyWidth = TranscriptBubbleGeometry.bodyWidth(columnWidth: columnWidth, role: role)
        let measurer = MessageBlockMeasurer()
        let heights = measurer.blockHeights(blocks, bodyWidth: bodyWidth)
        let reserved = TranscriptBubbleGeometry.rowHeight(
            blocksHeight: measurer.blocksHeight(fromBlockHeights: heights), role: role)

        let cell = TranscriptBubbleCellView()
        cell.configure(
            blocks: blocks,
            blockHeights: heights,
            sourceText: TranscriptBubbleGeometry.text(for: item),
            role: role,
            peerHeader: peerHeader,
            accessibilityAttribution: TranscriptBubbleGeometry.accessibilityAttribution(for: item),
            bodyWidth: bodyWidth,
            columnWidth: columnWidth,
            cachedHeight: reserved,
            onLinkClicked: nil)
        cell.layoutSubtreeIfNeeded()
        return (reserved, cell)
    }

    /// Every string the subtree actually draws — labels, buttons, and prose text
    /// views — trimmed, in tree order.
    private static func drawnStrings(in view: NSView) -> [String] {
        var found: [String] = []
        func walk(_ v: NSView) {
            if let button = v as? NSButton {
                found.append(button.title)
            } else if let field = v as? NSTextField {
                found.append(field.stringValue)
            } else if let text = v as? NSTextView {
                found.append(text.string)
            }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        func walk(_ v: NSView) {
            if let button = v as? NSButton { found.append(button) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    // MARK: - Height budget

    /// The header's budget is one header line plus the one inter-block gap the
    /// stack puts between it and the first message block — and it applies to the
    /// peer role and to nothing else.
    @Test("only the peer role budgets a header line")
    func headerBudgetIsPeerOnly() {
        let g = TranscriptBubbleGeometry.self
        #expect(g.headerHeight(for: .peer) == g.peerHeaderLineHeight + g.interBlockSpacing)
        #expect(g.headerHeight(for: .user) == 0)
        #expect(g.headerHeight(for: .assistant) == 0)
        #expect(g.peerHeaderLineHeight > 0)
    }

    /// The regression this task most easily causes: a user or assistant row must
    /// reserve EXACTLY what it reserved before the header existed, and a peer row
    /// exactly one header more.
    @Test("a non-peer row's reserved height is unchanged; a peer row grows by one header")
    func nonPeerRowHeightIsUnchanged() {
        let g = TranscriptBubbleGeometry.self
        // The pre-change arithmetic, spelled out rather than derived, so a change
        // to the chrome constants cannot quietly move it.
        #expect(g.rowHeight(blocksHeight: 100, role: .user) == 132)
        #expect(g.rowHeight(blocksHeight: 100, role: .assistant) == 132)
        #expect(g.rowHeight(blocksHeight: 0, role: .user) == 32)

        #expect(g.rowHeight(blocksHeight: 100, role: .peer)
            == 132 + g.headerHeight(for: .peer))
        // …and the stack-height form, which the realized cell uses, adds no header
        // at all — the stack already contains it.
        #expect(g.rowHeight(stackHeight: 100) == 132)
    }

    // MARK: - Measure == render

    @Test("a peer row's realized height equals the height the table reserved")
    func peerCellRealizesAtTheReservedRowHeight() {
        let sender = verifiedSender("Acme Deploy Watch")
        let target = worktree("Acme Deploy Watch")
        let header = TranscriptBubbleGeometry.peerHeader(
            for: peerItem(sender), worktrees: [target], navigate: { _ in })
        #expect(header?.isLink == true, "the fixture sender must resolve, or this measures nothing")

        let rendered = measureAndRender(
            item: peerItem(sender), role: .peer, peerHeader: header)
        #expect(abs(rendered.cell.realizedRowHeight - rendered.reserved) <= 1.0,
                Comment(rawValue: "peer bubble must realize at the reserved height "
                    + "(realized=\(rendered.cell.realizedRowHeight) reserved=\(rendered.reserved))"))
    }

    /// The same body as a USER prompt must realize at its own reserved height, and
    /// that height must be exactly one header shorter than the peer row's. Same
    /// text, and `.user`/`.peer` share their body width, so the difference is the
    /// header and nothing else.
    @Test("a user row with the same body is unchanged and exactly one header shorter")
    func userCellIsUnaffectedByThePeerHeader() {
        let userItem = TranscriptItem.userPrompt(id: "u1", text: body, timestamp: nil)
        let user = measureAndRender(item: userItem, role: .user, peerHeader: nil)
        #expect(abs(user.cell.realizedRowHeight - user.reserved) <= 1.0,
                Comment(rawValue: "user bubble must realize at the reserved height "
                    + "(realized=\(user.cell.realizedRowHeight) reserved=\(user.reserved))"))

        let sender = verifiedSender("Acme Deploy Watch")
        let header = TranscriptBubbleGeometry.peerHeader(
            for: peerItem(sender), worktrees: [], navigate: nil)
        let peer = measureAndRender(item: peerItem(sender), role: .peer, peerHeader: header)

        let delta = peer.reserved - user.reserved
        #expect(abs(delta - TranscriptBubbleGeometry.headerHeight(for: .peer)) <= 0.5,
                Comment(rawValue: "a peer row must be exactly one header taller than the same "
                    + "body as a user prompt (delta=\(delta) "
                    + "header=\(TranscriptBubbleGeometry.headerHeight(for: .peer)))"))
    }

    // MARK: - What the header says

    @Test("a verified sender draws its peer name; an asserted one is marked unverified")
    func displayNameMarksAssertedSenders() {
        #expect(PeerHeaderChrome.displayName(for: verifiedSender("Acme Deploy Watch"))
            == "Acme Deploy Watch")

        let asserted = PeerHeaderChrome.displayName(for: assertedSender("acme-bot"))
        #expect(asserted.hasPrefix("acme-bot"))
        #expect(asserted.hasSuffix(PeerHeaderChrome.assertedSuffix))
        #expect(asserted != "acme-bot", "an asserted label must never read as a confirmed identity")
    }

    /// The attribution is CHROME: it is drawn beside the body, never inside it,
    /// and the message text the bubble copies out is the body alone.
    @Test("the sender name is drawn outside the markdown body, never concatenated into it")
    func headerIsChromeNotBodyText() {
        let sender = verifiedSender("Acme Deploy Watch")
        let header = TranscriptBubbleGeometry.peerHeader(
            for: peerItem(sender), worktrees: [worktree("Acme Deploy Watch")],
            navigate: { _ in })
        let rendered = measureAndRender(item: peerItem(sender), role: .peer, peerHeader: header)

        let drawn = Self.drawnStrings(in: rendered.cell)
        #expect(drawn.contains(where: { $0.contains("Acme Deploy Watch") }),
                "the bubble must draw the sender name, got \(drawn)")
        #expect(drawn.contains(where: { $0.contains("acme-prod") }),
                "the bubble must still draw its body, got \(drawn)")

        // The body itself carries none of it: the header is a sibling view, and
        // `sourceText` (what ⌘C copies) is the message.
        let prose = drawn.filter { $0.contains("acme-prod") }
        #expect(prose.allSatisfy({ !$0.contains("Acme Deploy Watch") }),
                "the sender name must not appear inside the message body, got \(prose)")
        #expect(!body.contains("Acme Deploy Watch"))
    }

    // MARK: - The three link shapes

    @Test("a resolved sender is a button that navigates to its worktree")
    func resolvedSenderNavigates() throws {
        let target = worktree("Acme Deploy Watch")
        let sender = verifiedSender("Acme Deploy Watch")
        let navigated = NavigationRecorder()
        // TranscriptPeerHeader carries a `navigate` closure, so it is not
        // Sendable and cannot go through `#require`.
        guard let header = TranscriptBubbleGeometry.peerHeader(
            for: peerItem(sender), worktrees: [target],
            navigate: { navigated.ids.append($0) }
        ) else { Issue.record("a peer item must produce a header"); return }
        #expect(header.worktreeID == target.id)
        #expect(header.isLink)

        let rendered = measureAndRender(item: peerItem(sender), role: .peer, peerHeader: header)
        let button = try #require(Self.buttons(in: rendered.cell).first,
                                  "a resolved sender must render a clickable name")
        // Fire the button's own target/action rather than `performClick(nil)`:
        // this asserts the wiring the click depends on without also depending on
        // AppKit delivering a click to a view that is in no window.
        let action = try #require(button.action, "the sender name must carry an action")
        let receiver = try #require(button.target as? NSObject,
                                    "the sender name must carry a target")
        _ = receiver.perform(action, with: button)
        #expect(navigated.ids == [target.id])
    }

    @Test("a verified but unresolved sender is plain text with no click affordance")
    func verifiedUnresolvedSenderIsPlainText() throws {
        let sender = verifiedSender("Acme Deploy Watch")
        // Two worktrees share the name, so the resolver refuses to guess.
        let ambiguous = [worktree("Acme Deploy Watch"), worktree("Acme Deploy Watch")]
        guard let header = TranscriptBubbleGeometry.peerHeader(
            for: peerItem(sender), worktrees: ambiguous, navigate: { _ in }
        ) else { Issue.record("a peer item must produce a header"); return }
        #expect(header.worktreeID == nil)
        #expect(!header.isLink)

        let rendered = measureAndRender(item: peerItem(sender), role: .peer, peerHeader: header)
        #expect(Self.buttons(in: rendered.cell).isEmpty,
                "an unresolved sender must offer no navigation")
        let drawn = Self.drawnStrings(in: rendered.cell)
        #expect(drawn.contains(where: { $0.contains("Acme Deploy Watch") }),
                "the name still renders, it simply is not clickable — got \(drawn)")
    }

    @Test("an asserted sender never links, even when its label matches a worktree")
    func assertedSenderNeverLinks() throws {
        let sender = assertedSender("acme-bot")
        guard let header = TranscriptBubbleGeometry.peerHeader(
            for: peerItem(sender), worktrees: [worktree("acme-bot")], navigate: { _ in }
        ) else { Issue.record("a peer item must produce a header"); return }
        #expect(!header.verified)
        #expect(header.worktreeID == nil)
        #expect(!header.isLink)

        let rendered = measureAndRender(item: peerItem(sender), role: .peer, peerHeader: header)
        #expect(Self.buttons(in: rendered.cell).isEmpty,
                "verification gates the link, not whether the label matches a name")
        let drawn = Self.drawnStrings(in: rendered.cell)
        #expect(drawn.contains(where: { $0.hasSuffix(PeerHeaderChrome.assertedSuffix) }),
                "an asserted sender must draw its unverified marker, got \(drawn)")
    }

    // MARK: - Nothing else grows a header

    @Test("no other item kind produces a sender header")
    func nonPeerItemsHaveNoHeader() {
        let worktrees = [worktree("Acme Deploy Watch")]
        let user = TranscriptItem.userPrompt(id: "u", text: body, timestamp: nil)
        let assistant = TranscriptItem.assistantText(id: "a", text: body, timestamp: nil, usage: nil)
        #expect(TranscriptBubbleGeometry.peerHeader(
            for: user, worktrees: worktrees, navigate: nil) == nil)
        #expect(TranscriptBubbleGeometry.peerHeader(
            for: assistant, worktrees: worktrees, navigate: nil) == nil)
    }

    /// Requirement check rather than new behaviour: a peer message must reach the
    /// bubble renderer at all, or none of the above is on screen.
    @Test("a peer message routes to a chat-bubble node")
    func peerMessageRoutesToAChatBubbleNode() throws {
        let sender = verifiedSender("Acme Deploy Watch")
        let nodes = transcriptRenderNodes(from: [peerItem(sender)])
        let node = try #require(nodes.first)
        guard case .chatBubble(let item) = node.kind else {
            Issue.record("a peer message must render as a chat bubble, got \(node.kind)")
            return
        }
        guard case .peerMessage(_, let carried, let text, _, _) = item else {
            Issue.record("the bubble must carry the peer item itself, got \(item)")
            return
        }
        #expect(carried == sender)
        #expect(text == body)
        #expect(TranscriptBubbleGeometry.role(for: item) == .peer)
    }
}
