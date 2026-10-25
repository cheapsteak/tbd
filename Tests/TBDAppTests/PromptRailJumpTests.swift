import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// Jumps to a prompt in the transcript table, driven headlessly in
/// `TableTranscriptScene`: a jump puts its target 16pt below the viewport top
/// and pins it there while estimated rows above it realize, and holds it as the
/// active prompt. A reader scroll or re-laid rows end both; the coordinator's
/// own tail-follow ends only the pin, and a new prompt only the hold. Previous
/// and Next step through the prompts.
@Suite("Prompt rail jumps")
@MainActor
struct PromptRailJumpTests {
    private static let promptCount = 60
    private static var inset: CGFloat { TableTranscriptView.Coordinator.jumpTopInset }

    /// Replies of 12–20 sentences, so every exchange is taller than the 120pt
    /// probe band of the 600pt viewport.
    nonisolated private static func tallReplies(_ index: Int) -> Int { 12 + (index * 5) % 9 }

    /// The scene over `items` with the bounds observer running, primed parked
    /// at the end, as a pane opens on a long session.
    ///
    /// `prime(nodes:)` settles with the clip at the top, which realizes and
    /// measures the first screen of rows. Here every round scrolls to the end
    /// before it settles instead. The autohiding scroller's arrival after the
    /// first round changes the column width, and the next round's width change
    /// drops every height measured before it, so afterwards only the bottom
    /// window and the rows realized at the end are exact; rows far above carry
    /// estimates, which is what a jump has to pin against.
    ///
    /// Throws first if AppKit's own row-height estimation is on in this
    /// process: AppKit would then move the clip itself, and every pin and
    /// hold assertion here would fail for that reason instead of their own.
    private static func primedAtEnd(
        items: [TranscriptItem],
        appState: AppState,
        makeCoordinator: (@MainActor (TranscriptCardContext) -> TableTranscriptView.Coordinator)? = nil
    ) throws -> TableTranscriptScene {
        let scene = TableTranscriptScene(items: items, appState: appState, makeCoordinator: makeCoordinator)
        scene.coordinator.startObservingScroll()
        let nodes = transcriptRenderNodes(from: items)
        for _ in 0..<4 {
            let widthAtUpdate = scene.tableView.bounds.width
            // Keep the clip at the end while the update reloads the table, so
            // whatever realizes is at the end.
            scene.coordinator.scrollToEnd(animated: false)
            scene.coordinator.update(
                nodes: nodes, atBottom: .constant(true), activityToggleToken: 0, linkRoot: "")
            scene.tableView.tile()
            scene.coordinator.scrollToEnd(animated: false)
            scene.settle()
            if scene.tableView.bounds.width == widthAtUpdate {
                try scene.requireDelegateRowHeights()
                return scene
            }
        }
        Issue.record("the table's column width never settled: \(scene.tableView.bounds.width)")
        return scene
    }

    /// Lets a jump settle as it does in a live pane: AppKit lays out and
    /// realizes the rows the jump brought on screen, correcting their heights,
    /// the jump's deferred re-pin runs, and the table reaches a fixed point.
    private static func settleJump(_ scene: TableTranscriptScene) async {
        scene.tableView.layoutSubtreeIfNeeded()
        await drainMainQueue()
        scene.settle()
    }

    /// Names what last ended the jump's pin or hold, so a hold that ended early
    /// says why in the failure.
    private static func releaseNote(_ scene: TableTranscriptScene) -> Comment {
        let reason = scene.coordinator.lastJumpRelease.map { "\($0)" } ?? "none"
        return Comment(rawValue: "last jump release: \(reason)")
    }

    /// Adds height to one row from outside the coordinator's correction path,
    /// as AppKit does when it swaps its own row-height estimate for the
    /// delegate's height.
    private final class ResizableRowCoordinator: TableTranscriptView.Coordinator {
        var extraHeight: (id: String, points: CGFloat)?

        override func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            let height = super.tableView(tableView, heightOfRow: row)
            guard let extraHeight, row < nodes.count, nodes[row].id == extraHeight.id else { return height }
            return height + extraHeight.points
        }
    }

    /// An AskUserQuestion card whose question wraps. Prose rows estimate to
    /// within a line of their measurement, often exactly, but this card the
    /// estimator under-reserves by construction (`card/askUserQuestion-wrapping`
    /// in `TranscriptEstimatorAccuracyTests`, 36pt at the calibrated text size),
    /// so the card's correction when it realizes moves every row below it.
    private static let wrappingAskCardJSON =
        #"{"questions":[{"question":"This question is deliberately very long indeed, so long that it must wrap across at least three separate lines inside the card at either of the column widths the transcript pane is ever laid out at, which is the shape a count-based model cannot see.","header":"Sizing","multiSelect":false,"options":[{"label":"A","description":"first"},{"label":"B","description":"second"}]}]}"#

    @Test("a jump pins a far row with an estimated height 16pt below the top")
    func jumpPinsAFarEstimatedRow() async throws {
        let suiteName = "prompt-rail-jump-pin-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        // The row right above prompt 5 is the card, so the jump brings it on
        // screen and its correction is certain to land above the target.
        var items = PromptRailFixtures.conversation(prompts: Self.promptCount, replySentences: Self.tallReplies)
        let replyIndex = try #require(items.firstIndex { $0.id == "a-4" })
        items.insert(.toolCall(
            id: "ask-4",
            name: "AskUserQuestion",
            inputJSON: Self.wrappingAskCardJSON,
            inputTruncatedTo: nil,
            result: ToolResult(text: "A", truncatedTo: nil, isError: false),
            subagent: nil,
            timestamp: nil), at: replyIndex + 1)
        let scene = try Self.primedAtEnd(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        let entries = scene.coordinator.promptEntries
        try #require(entries.count == Self.promptCount)
        let target = entries[5]
        let rowAbove = scene.coordinator.nodes[target.rowIndex - 1]
        try #require(rowAbove.id == "ask-4")
        try #require(scene.coordinator.cachedExactHeight(for: rowAbove) == nil,
                     "precondition: the card above the target carries only an estimate")

        scene.coordinator.jump(toNodeID: target.id)
        let topAtJump = scene.tableView.rect(ofRow: target.rowIndex).minY
        let firstFrame = scene.screenOffset(ofRow: target.rowIndex)
        #expect(abs(firstFrame - Self.inset) <= 1,
                Comment(rawValue: "the first frame put the target at \(firstFrame) pt, not \(Self.inset)"))

        // Lay out the rows the jump brought on screen: the card realizes and
        // corrects here. Read before the deferred re-pin gets a turn, so this
        // pins the synchronous re-pin in `correctRowHeightIfNeeded` alone.
        scene.tableView.layoutSubtreeIfNeeded()
        let afterLayout = scene.screenOffset(ofRow: target.rowIndex)
        #expect(abs(afterLayout - Self.inset) <= 1,
                Comment(rawValue: "after layout, before the deferred re-pin, the target sat at \(afterLayout) pt; "
                    + Self.releaseNote(scene).rawValue))

        await drainMainQueue()
        scene.settle()

        #expect(scene.coordinator.cachedExactHeight(for: rowAbove) != nil, "the card above the target realized")
        let moved = scene.tableView.rect(ofRow: target.rowIndex).minY - topAtJump
        try #require(abs(moved) > 1,
                     Comment(rawValue: "precondition: rows above the target corrected by more than the 1pt "
                         + "tolerance, so holding it took a re-pin (it moved \(moved) pt in the document)"))
        let settled = scene.screenOffset(ofRow: target.rowIndex)
        #expect(abs(settled - Self.inset) <= 1,
                Comment(rawValue: "the target drifted to \(settled) pt as rows around it realized; "
                    + Self.releaseNote(scene).rawValue))
        #expect(scene.coordinator.activePromptIndex == 5, Self.releaseNote(scene))
        #expect(scene.coordinator.pendingJumpAnchor?.id == target.id, Self.releaseNote(scene))
    }

    /// AppKit moves the clip itself to follow content that moved under it: it
    /// clamps as the document shrinks, and re-anchors as it swaps its own
    /// row-height estimates for the delegate's heights. That is not the
    /// reader, so the pin and the hold stay.
    @Test("AppKit following content that moved under the clip keeps the jump's pin and hold")
    func contentFollowKeepsHold() async throws {
        let suiteName = "prompt-rail-jump-follow-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: 30, replySentences: Self.tallReplies)
        let scene = try Self.primedAtEnd(
            items: items, appState: appState, makeCoordinator: { ResizableRowCoordinator(context: $0) })
        defer { withExtendedLifetime(scene.coordinator) {} }
        let coordinator = try #require(scene.coordinator as? ResizableRowCoordinator)
        let entries = coordinator.promptEntries
        try #require(entries.count == 30)
        let target = entries[10]
        let clip = scene.scrollView.contentView

        coordinator.jump(toNodeID: target.id)
        await Self.settleJump(scene)
        try #require(coordinator.pendingJumpAnchor?.id == target.id, Self.releaseNote(scene))
        let origin = clip.bounds.minY
        let topBefore = scene.tableView.rect(ofRow: target.rowIndex).minY

        // The row above the target grows from outside the correction path...
        let rowAbove = target.rowIndex - 1
        coordinator.extraHeight = (id: coordinator.nodes[rowAbove].id, points: 40)
        scene.tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: rowAbove))
        scene.tableView.tile()
        let grownBy = scene.tableView.rect(ofRow: target.rowIndex).minY - topBefore
        try #require(abs(grownBy - 40) <= 1,
                     Comment(rawValue: "precondition: the target moved 40pt down the document (moved \(grownBy) pt)"))
        // ...and AppKit moves the clip after it, so the rows below keep their
        // places on screen.
        clip.scroll(to: NSPoint(x: 0, y: origin + grownBy))
        scene.scrollView.reflectScrolledClipView(clip)

        #expect(coordinator.heldJumpTargetID == target.id, Self.releaseNote(scene))
        #expect(coordinator.pendingJumpAnchor?.id == target.id, Self.releaseNote(scene))
        #expect(coordinator.lastJumpRelease == nil)
        let offset = scene.screenOffset(ofRow: target.rowIndex)
        #expect(abs(offset - Self.inset) <= 1, Comment(rawValue: "the target sat at \(offset) pt"))

        // A reader scroll still releases both, and says so.
        scene.scroll(toY: clip.bounds.minY + 100)
        #expect(coordinator.heldJumpTargetID == nil)
        #expect(coordinator.pendingJumpAnchor == nil)
        #expect(coordinator.lastJumpRelease == .readerScroll)
    }

    /// A size change moves no content under the clip and the reader's place
    /// with it: the pane growing or shrinking, or the scroller claiming width.
    @Test("a viewport size change keeps the jump's pin and hold")
    func sizeChangeKeepsHold() async throws {
        let suiteName = "prompt-rail-jump-resize-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: Self.promptCount, replySentences: Self.tallReplies)
        let scene = try Self.primedAtEnd(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        let entries = scene.coordinator.promptEntries
        try #require(entries.count == Self.promptCount)
        let clip = scene.scrollView.contentView

        scene.coordinator.jump(toNodeID: entries[20].id)
        await Self.settleJump(scene)
        try #require(scene.coordinator.pendingJumpAnchor != nil, Self.releaseNote(scene))
        let origin = clip.bounds.minY

        scene.scrollView.frame = NSRect(
            x: 0, y: 0, width: TableTranscriptScene.width, height: TableTranscriptScene.viewportHeight - 100)
        scene.settle()
        try #require(clip.bounds.height < TableTranscriptScene.viewportHeight - 50,
                     Comment(rawValue: "precondition: the viewport got shorter (\(clip.bounds.height) pt)"))
        try #require(abs(clip.bounds.minY - origin) <= 0.5,
                     Comment(rawValue: "precondition: the origin stayed (\(origin) → \(clip.bounds.minY))"))

        #expect(scene.coordinator.heldJumpTargetID == entries[20].id, Self.releaseNote(scene))
        #expect(scene.coordinator.pendingJumpAnchor?.id == entries[20].id, Self.releaseNote(scene))
    }

    @Test("a reader scroll releases the jump anchor and the held target")
    func readerScrollReleasesAnchor() async throws {
        let suiteName = "prompt-rail-jump-scroll-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: Self.promptCount, replySentences: Self.tallReplies)
        let scene = try Self.primedAtEnd(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        let entries = scene.coordinator.promptEntries
        try #require(entries.count == Self.promptCount)

        scene.coordinator.jump(toNodeID: entries[20].id)
        await Self.settleJump(scene)
        // The coordinator's own re-pins while rows realized did not release it.
        #expect(scene.coordinator.pendingJumpAnchor?.id == entries[20].id, Self.releaseNote(scene))
        #expect(scene.coordinator.heldJumpTargetID == entries[20].id, Self.releaseNote(scene))

        scene.scroll(toY: scene.scrollView.contentView.bounds.minY + 200)

        #expect(scene.coordinator.pendingJumpAnchor == nil, Self.releaseNote(scene))
        #expect(scene.coordinator.heldJumpTargetID == nil, Self.releaseNote(scene))
        #expect(scene.coordinator.lastJumpRelease == .readerScroll)
    }

    /// Away from the bottom nothing tail-follows, so this isolates what an
    /// append itself does: a reply keeps both the pin and the held target, and
    /// a new prompt keeps the pin but ends the hold.
    @Test("an append keeps the jump anchor and the target where it landed")
    func appendKeepsAnchor() async throws {
        let suiteName = "prompt-rail-jump-append-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: Self.promptCount, replySentences: Self.tallReplies)
        let scene = try Self.primedAtEnd(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        let entries = scene.coordinator.promptEntries
        try #require(entries.count == Self.promptCount)
        let target = entries[20]

        scene.coordinator.jump(toNodeID: target.id)
        await Self.settleJump(scene)
        let offsetBefore = scene.screenOffset(ofRow: target.rowIndex)

        // A reply row arrives below.
        let withReply = items + [.assistantText(
            id: "a-59-more", text: "A further reply sentence.", timestamp: nil, usage: nil)]
        let replyNodes = transcriptRenderNodes(from: withReply)
        try #require(TranscriptStreamPlan.step(previous: scene.coordinator.previousNodes, next: replyNodes)
                         == .append(fromIndex: items.count),
                     "precondition: the reply arrives as an append")
        scene.coordinator.update(
            nodes: replyNodes, atBottom: .constant(false), activityToggleToken: 0, linkRoot: "")

        #expect(scene.coordinator.pendingJumpAnchor?.id == target.id, Self.releaseNote(scene))
        #expect(scene.coordinator.heldJumpTargetID == target.id, Self.releaseNote(scene))
        #expect(scene.coordinator.activePromptIndex == 20)
        let afterReply = scene.screenOffset(ofRow: target.rowIndex)
        #expect(abs(afterReply - offsetBefore) <= 1,
                Comment(rawValue: "the reply moved the target: before=\(offsetBefore) after=\(afterReply)"))

        // A new prompt arrives below: the pin stays, the hold ends, and the rule
        // still picks the target, whose top sits above the probe line.
        let withPrompt = transcriptRenderNodes(
            from: withReply + [.userPrompt(id: "p-60", text: "Prompt 60", timestamp: nil)])
        try #require(TranscriptStreamPlan.step(previous: scene.coordinator.previousNodes, next: withPrompt)
                         == .append(fromIndex: withReply.count),
                     "precondition: the new prompt arrives as an append")
        scene.coordinator.update(
            nodes: withPrompt, atBottom: .constant(false), activityToggleToken: 0, linkRoot: "")

        #expect(scene.coordinator.pendingJumpAnchor?.id == target.id, Self.releaseNote(scene))
        #expect(scene.coordinator.heldJumpTargetID == nil, Self.releaseNote(scene))
        #expect(scene.coordinator.promptEntries.count == Self.promptCount + 1)
        #expect(scene.coordinator.activePromptIndex == 20)
        let firstFrame = scene.screenOffset(ofRow: target.rowIndex)
        #expect(abs(firstFrame - offsetBefore) <= 1,
                Comment(rawValue: "the prompt moved the target: before=\(offsetBefore) after=\(firstFrame)"))

        await Self.settleJump(scene)

        let settled = scene.screenOffset(ofRow: target.rowIndex)
        #expect(abs(settled - offsetBefore) <= 1,
                Comment(rawValue: "the target moved once the appends settled: before=\(offsetBefore) after=\(settled)"))
        #expect(scene.coordinator.pendingJumpAnchor?.id == target.id, Self.releaseNote(scene))
    }

    /// Short replies on the last two exchanges, so both fit on the last screen
    /// and a jump to prompt 58 clamps at the end.
    nonisolated private static func shortLastReplies(_ index: Int) -> Int { index >= 58 ? 3 : tallReplies(index) }

    /// The scene from `shortLastReplies`, parked mid-transcript and then jumped
    /// to prompt 58, so the clip sits at the end with 58 held.
    private static func jumpedToPrompt58(appState: AppState) async throws -> (TableTranscriptScene, [TranscriptItem]) {
        let items = PromptRailFixtures.conversation(prompts: promptCount, replySentences: shortLastReplies)
        let scene = try primedAtEnd(items: items, appState: appState)
        let entries = scene.coordinator.promptEntries
        try #require(entries.count == promptCount)
        scene.park(row: entries[40].rowIndex, below: 40)
        scene.coordinator.jump(toNodeID: entries[58].id)
        await settleJump(scene)
        try #require(scene.gapToBottom <= 1,
                     Comment(rawValue: "precondition: prompt 58 clamps at the end (gap \(scene.gapToBottom) pt)"))
        try #require(scene.coordinator.heldJumpTargetID == "p-58", Self.releaseNote(scene))
        try #require(scene.coordinator.pendingJumpAnchor != nil, Self.releaseNote(scene))
        return (scene, items)
    }

    /// The tail-follow is the coordinator's own scroll, not the reader's: it
    /// ends the pin, which would fight it, but the target stays active.
    @Test("following the tail after a jump to the end keeps the target active and ends the pin")
    func tailFollowKeepsHeldTarget() async throws {
        let suiteName = "prompt-rail-jump-tail-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let (scene, items) = try await Self.jumpedToPrompt58(appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }

        // The last reply streams more text, with the clip at the end.
        var streamed = items
        streamed[streamed.count - 1] = .assistantText(
            id: "a-59",
            text: String(repeating: "A reply sentence whose prose wraps across the column. ", count: 12),
            timestamp: nil,
            usage: nil)
        let streamedNodes = transcriptRenderNodes(from: streamed)
        try #require(TranscriptStreamPlan.step(previous: scene.coordinator.previousNodes, next: streamedNodes)
                         == .updateLast,
                     "precondition: the reply token arrives as a tail re-render")
        scene.coordinator.update(
            nodes: streamedNodes, atBottom: .constant(true), activityToggleToken: 0, linkRoot: "")
        // Lay the grown row out, as a live pane has by the tail-follow's turn.
        scene.tableView.layoutSubtreeIfNeeded()
        try #require(scene.gapToBottom > 1,
                     Comment(rawValue: "precondition: the reply grew below the viewport, so the tail-follow "
                         + "has to scroll (gap \(scene.gapToBottom) pt)"))

        await drainMainQueue()

        #expect(scene.gapToBottom <= 1,
                Comment(rawValue: "the tail-follow did not reach the end (gap \(scene.gapToBottom) pt)"))
        #expect(scene.coordinator.heldJumpTargetID == "p-58", Self.releaseNote(scene))
        #expect(scene.coordinator.activePromptIndex == 58, Self.releaseNote(scene))
        #expect(scene.coordinator.pendingJumpAnchor == nil, Self.releaseNote(scene))
        #expect(scene.coordinator.lastJumpRelease == .tailFollow)
    }

    @Test("a new prompt after a held jump target ends the hold")
    func newPromptReleasesHeldTarget() async throws {
        let suiteName = "prompt-rail-jump-newprompt-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let (scene, items) = try await Self.jumpedToPrompt58(appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }

        let grown = transcriptRenderNodes(
            from: items + [.userPrompt(id: "p-60", text: "Prompt 60", timestamp: nil)])
        try #require(TranscriptStreamPlan.step(previous: scene.coordinator.previousNodes, next: grown)
                         == .append(fromIndex: items.count),
                     "precondition: the new prompt arrives as an append")
        scene.coordinator.update(
            nodes: grown, atBottom: .constant(true), activityToggleToken: 0, linkRoot: "")
        #expect(scene.coordinator.heldJumpTargetID == nil, "the outline rebuild must end the hold at once")
        #expect(scene.coordinator.lastJumpRelease == .newPrompt)
        scene.tableView.layoutSubtreeIfNeeded()
        await drainMainQueue()

        let lastIndex = scene.coordinator.promptEntries.count - 1
        #expect(scene.coordinator.promptEntries.last?.id == "p-60")
        #expect(scene.gapToBottom <= 1,
                Comment(rawValue: "the tail-follow did not reach the end (gap \(scene.gapToBottom) pt)"))
        #expect(scene.coordinator.heldJumpTargetID == nil, Self.releaseNote(scene))
        #expect(scene.coordinator.activePromptIndex == lastIndex)
        #expect(scene.coordinator.pendingJumpAnchor == nil, Self.releaseNote(scene))
    }

    @Test("a prepend and a width change each release the jump anchor")
    func prependAndWidthChangeRelease() async throws {
        let suiteName = "prompt-rail-jump-release-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: Self.promptCount, replySentences: Self.tallReplies)
        let scene = try Self.primedAtEnd(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        let entries = scene.coordinator.promptEntries
        try #require(entries.count == Self.promptCount)
        let primedWidth = scene.tableView.bounds.width

        // Prepend: earlier history lands at the front while the jump is held.
        scene.coordinator.jump(toNodeID: entries[20].id)
        await Self.settleJump(scene)
        try #require(scene.coordinator.pendingJumpAnchor != nil, Self.releaseNote(scene))
        let front: [TranscriptItem] = (0..<2).map { index in
            .assistantText(
                id: "front-\(index)",
                text: String(repeating: "Earlier history arriving above the reader. ", count: 20),
                timestamp: nil,
                usage: nil)
        }
        let prepended = transcriptRenderNodes(from: front + items)
        scene.coordinator.update(
            nodes: prepended, atBottom: .constant(false), activityToggleToken: 0, linkRoot: "",
            prependToken: 1)

        #expect(scene.coordinator.pendingJumpAnchor == nil, Self.releaseNote(scene))
        #expect(scene.coordinator.heldJumpTargetID == nil, Self.releaseNote(scene))
        #expect(scene.coordinator.lastJumpRelease == .prepend)
        // The prepend holds the reader's place with its own anchor instead, and
        // a jump moves the reader away from it, so a jump supersedes it.
        try #require(scene.coordinator.pendingPrependAnchor != nil)
        let shifted = scene.coordinator.promptEntries
        try #require(shifted.first?.rowIndex == 2)
        scene.coordinator.jump(toNodeID: shifted[30].id)
        #expect(scene.coordinator.pendingPrependAnchor == nil)

        // Width change. The resize changes the clip's size, not its origin, so
        // the bounds observer keeps the hold; jump again afterwards anyway, so
        // only the update's width-change path can release it.
        scene.scrollView.frame = NSRect(
            x: 0, y: 0, width: TableTranscriptScene.width - 120, height: TableTranscriptScene.viewportHeight)
        scene.settle()
        try #require(scene.tableView.bounds.width < primedWidth - 60,
                     Comment(rawValue: "precondition: the column narrowed (\(scene.tableView.bounds.width) pt)"))
        scene.coordinator.jump(toNodeID: shifted[30].id)
        try #require(scene.coordinator.pendingJumpAnchor != nil, Self.releaseNote(scene))

        // Same nodes and the same prepend token: only the width moved.
        scene.coordinator.update(
            nodes: prepended, atBottom: .constant(false), activityToggleToken: 0, linkRoot: "",
            prependToken: 1)

        #expect(scene.coordinator.pendingJumpAnchor == nil, Self.releaseNote(scene))
        #expect(scene.coordinator.heldJumpTargetID == nil, Self.releaseNote(scene))
        #expect(scene.coordinator.lastJumpRelease == .widthChange)
    }

    @Test("a jump to an unknown id leaves the scroll and any held jump alone")
    func unknownIDLeavesScroll() async throws {
        let suiteName = "prompt-rail-jump-unknown-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: Self.promptCount, replySentences: Self.tallReplies)
        let scene = try Self.primedAtEnd(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        let entries = scene.coordinator.promptEntries
        try #require(entries.count == Self.promptCount)
        let clip = scene.scrollView.contentView

        scene.park(row: entries[20].rowIndex, below: 100)
        let parked = clip.bounds.minY
        scene.coordinator.jump(toNodeID: "nope")
        #expect(clip.bounds.minY == parked)
        #expect(scene.coordinator.pendingJumpAnchor == nil, Self.releaseNote(scene))
        #expect(scene.coordinator.heldJumpTargetID == nil, Self.releaseNote(scene))

        scene.coordinator.jump(toNodeID: entries[30].id)
        await Self.settleJump(scene)
        let jumped = clip.bounds.minY
        scene.coordinator.jump(toNodeID: "nope")
        #expect(clip.bounds.minY == jumped)
        #expect(scene.coordinator.heldJumpTargetID == entries[30].id, Self.releaseNote(scene))
        #expect(scene.coordinator.pendingJumpAnchor?.id == entries[30].id, Self.releaseNote(scene))
    }

    /// The last prompts cannot be scrolled to the top. The jump clamps at the
    /// end, and the held target, not the bottom rule, decides what is active.
    @Test("a jump near the end clamps at the bottom and holds its target active")
    func jumpNearEndHoldsTarget() async throws {
        let suiteName = "prompt-rail-jump-end-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(
            prompts: Self.promptCount, replySentences: Self.shortLastReplies)
        let scene = try Self.primedAtEnd(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        let entries = scene.coordinator.promptEntries
        try #require(entries.count == Self.promptCount)
        let clip = scene.scrollView.contentView
        scene.park(row: entries[40].rowIndex, below: 40)

        scene.coordinator.jump(toNodeID: entries[59].id)
        #expect(scene.gapToBottom <= 1, Comment(rawValue: "the jump left a gap of \(scene.gapToBottom) pt"))
        #expect(scene.coordinator.activePromptIndex == 59)

        // Prompt 58 is on the last screen too: the clip stays at the end, where
        // the bottom rule alone would pick 59.
        scene.coordinator.jump(toNodeID: entries[58].id)
        try #require(scene.gapToBottom <= 1,
                     Comment(rawValue: "precondition: prompt 58 clamps at the end (gap \(scene.gapToBottom) pt)"))
        #expect(scene.coordinator.activePromptIndex == 58)
        await Self.settleJump(scene)
        #expect(scene.coordinator.activePromptIndex == 58)

        // A reader scroll that stays within the bottom slack hands the choice
        // back to the rule.
        scene.scroll(toY: clip.bounds.minY - 1)
        #expect(scene.coordinator.heldJumpTargetID == nil, Self.releaseNote(scene))
        #expect(scene.coordinator.activePromptIndex == 59)
    }

    @Test("previous and next step through the prompts")
    func previousNextSemantics() async throws {
        let suiteName = "prompt-rail-jump-steps-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: Self.promptCount, replySentences: Self.tallReplies)
        let scene = try Self.primedAtEnd(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        let coordinator = scene.coordinator
        let entries = coordinator.promptEntries
        try #require(entries.count == Self.promptCount)
        let clip = scene.scrollView.contentView

        // Next from a prompt goes to the one after it.
        coordinator.jump(toNodeID: entries[20].id)
        await Self.settleJump(scene)
        coordinator.jumpToPrompt(.next)
        await Self.settleJump(scene)
        #expect(coordinator.activePromptIndex == 21)
        let atNext = scene.screenOffset(ofRow: entries[21].rowIndex)
        #expect(abs(atNext - Self.inset) <= 1, Comment(rawValue: "Next put prompt 21 at \(atNext) pt"))

        // 40pt inside exchange 21, Previous goes back to 21's own top.
        scene.park(row: entries[21].rowIndex, below: -40)
        try #require(coordinator.activePromptIndex == 21, "precondition: the reader is inside exchange 21")
        coordinator.jumpToPrompt(.previous)
        await Self.settleJump(scene)
        #expect(coordinator.activePromptIndex == 21)
        let atOwnTop = scene.screenOffset(ofRow: entries[21].rowIndex)
        #expect(abs(atOwnTop - Self.inset) <= 1, Comment(rawValue: "Previous put prompt 21 at \(atOwnTop) pt"))

        // At 21's top, Previous goes to the prompt before it.
        coordinator.jumpToPrompt(.previous)
        await Self.settleJump(scene)
        #expect(coordinator.activePromptIndex == 20)

        // From the top of the first prompt, Previous does nothing.
        coordinator.jump(toNodeID: entries[0].id)
        await Self.settleJump(scene)
        let atFirst = clip.bounds.minY
        // The first prompt is the first row, so the jump clamps to the very top
        // and nothing after it should move the clip.
        #expect(atFirst == 0,
                Comment(rawValue: "the clip left the top after the jump (\(atFirst) pt); "
                    + Self.releaseNote(scene).rawValue))
        coordinator.jumpToPrompt(.previous)
        #expect(clip.bounds.minY == atFirst, Self.releaseNote(scene))
        #expect(coordinator.activePromptIndex == 0, Self.releaseNote(scene))

        // From the last prompt, Next scrolls to the end and stops holding it.
        coordinator.jump(toNodeID: entries[59].id)
        await Self.settleJump(scene)
        coordinator.jumpToPrompt(.next)
        #expect(scene.gapToBottom <= 1, Comment(rawValue: "Next from the last prompt left \(scene.gapToBottom) pt"))
        #expect(coordinator.heldJumpTargetID == nil, Self.releaseNote(scene))
        #expect(coordinator.pendingJumpAnchor == nil, Self.releaseNote(scene))

        // Just short of the end the bottom rule makes the last prompt active;
        // Next still reaches the end.
        scene.scroll(toY: clip.bounds.minY - 5)
        try #require(coordinator.activePromptIndex == 59)
        try #require(scene.gapToBottom > 4)
        coordinator.jumpToPrompt(.next)
        #expect(scene.gapToBottom <= 1, Comment(rawValue: "Next from just short of the end left \(scene.gapToBottom) pt"))
    }

    @Test("with no active prompt, next goes to the first and previous does nothing")
    func stepsWithoutAnActivePrompt() throws {
        let suiteName = "prompt-rail-jump-noactive-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: 30, replySentences: Self.tallReplies)
        let scene = try Self.primedAtEnd(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        let entries = scene.coordinator.promptEntries
        try #require(entries.count == 30)
        let clip = scene.scrollView.contentView
        // As between an outline rebuild and the first index read against it.
        scene.coordinator.activePromptIndex = nil
        let origin = clip.bounds.minY
        try #require(origin > 0, "precondition: primed away from the top")

        scene.coordinator.jumpToPrompt(.previous)
        #expect(clip.bounds.minY == origin)
        #expect(scene.coordinator.heldJumpTargetID == nil, Self.releaseNote(scene))

        scene.coordinator.jumpToPrompt(.next)
        #expect(scene.coordinator.heldJumpTargetID == entries[0].id, Self.releaseNote(scene))
        #expect(scene.coordinator.activePromptIndex == 0)
        #expect(clip.bounds.minY == 0)
    }

    @Test("with no prompts, previous and next do nothing")
    func stepsWithoutPrompts() throws {
        let suiteName = "prompt-rail-jump-noprompts-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items: [TranscriptItem] = (0..<30).map { index in
            .assistantText(
                id: "a-\(index)",
                text: String(repeating: "Assistant prose with no prompt anywhere above it. ", count: 10),
                timestamp: nil,
                usage: nil)
        }
        let scene = try Self.primedAtEnd(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        try #require(scene.coordinator.promptEntries.isEmpty)
        let clip = scene.scrollView.contentView
        scene.park(row: 10, below: 0)
        let origin = clip.bounds.minY

        scene.coordinator.jumpToPrompt(.previous)
        scene.coordinator.jumpToPrompt(.next)

        #expect(clip.bounds.minY == origin)
        #expect(scene.coordinator.heldJumpTargetID == nil, Self.releaseNote(scene))
        #expect(scene.coordinator.pendingJumpAnchor == nil, Self.releaseNote(scene))
    }
}
