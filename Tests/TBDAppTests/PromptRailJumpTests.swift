import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// Jumps to a prompt in the transcript table, driven headlessly in
/// `TableTranscriptScene`: a jump puts its target 16pt below the viewport top
/// and holds it there while estimated rows above it realize, until the reader
/// scrolls or the rows are re-laid; Previous and Next step through the prompts.
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
    private static func primedAtEnd(items: [TranscriptItem], appState: AppState) -> TableTranscriptScene {
        let scene = TableTranscriptScene(items: items, appState: appState)
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
            if scene.tableView.bounds.width == widthAtUpdate { return scene }
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

    @Test("a jump pins a far row with an estimated height 16pt below the top")
    func jumpPinsAFarEstimatedRow() async throws {
        let suiteName = "prompt-rail-jump-pin-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: Self.promptCount, replySentences: Self.tallReplies)
        let scene = Self.primedAtEnd(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        let entries = scene.coordinator.promptEntries
        try #require(entries.count == Self.promptCount)
        let target = entries[5]
        let rowAbove = scene.coordinator.nodes[target.rowIndex - 1]
        try #require(scene.coordinator.cachedExactHeight(for: rowAbove) == nil,
                     "precondition: the row above the target carries only an estimate")

        scene.coordinator.jump(toNodeID: target.id)
        let firstFrame = scene.screenOffset(ofRow: target.rowIndex)
        #expect(abs(firstFrame - Self.inset) <= 1,
                Comment(rawValue: "the first frame put the target at \(firstFrame) pt, not \(Self.inset)"))

        await Self.settleJump(scene)

        #expect(scene.coordinator.cachedExactHeight(for: rowAbove) != nil,
                "the row above the target realized, so its height correction was exercised")
        let settled = scene.screenOffset(ofRow: target.rowIndex)
        #expect(abs(settled - Self.inset) <= 1,
                Comment(rawValue: "the target drifted to \(settled) pt as rows around it realized"))
        #expect(scene.coordinator.activePromptIndex == 5)
    }

    @Test("a reader scroll releases the jump anchor and the held target")
    func readerScrollReleasesAnchor() async throws {
        let suiteName = "prompt-rail-jump-scroll-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: Self.promptCount, replySentences: Self.tallReplies)
        let scene = Self.primedAtEnd(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        let entries = scene.coordinator.promptEntries
        try #require(entries.count == Self.promptCount)

        scene.coordinator.jump(toNodeID: entries[20].id)
        await Self.settleJump(scene)
        // The coordinator's own re-pins while rows realized did not release it.
        #expect(scene.coordinator.pendingJumpAnchor?.id == entries[20].id)
        #expect(scene.coordinator.heldJumpTargetID == entries[20].id)

        scene.scroll(toY: scene.scrollView.contentView.bounds.minY + 200)

        #expect(scene.coordinator.pendingJumpAnchor == nil)
        #expect(scene.coordinator.heldJumpTargetID == nil)
    }

    @Test("an append keeps the jump anchor and the target where it landed")
    func appendKeepsAnchor() async throws {
        let suiteName = "prompt-rail-jump-append-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: Self.promptCount, replySentences: Self.tallReplies)
        let scene = Self.primedAtEnd(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        let entries = scene.coordinator.promptEntries
        try #require(entries.count == Self.promptCount)
        let target = entries[20]

        scene.coordinator.jump(toNodeID: target.id)
        await Self.settleJump(scene)
        let offsetBefore = scene.screenOffset(ofRow: target.rowIndex)

        let grown = transcriptRenderNodes(
            from: items + [.userPrompt(id: "p-60", text: "Prompt 60", timestamp: nil)])
        try #require(TranscriptStreamPlan.step(previous: scene.coordinator.previousNodes, next: grown)
                         == .append(fromIndex: items.count),
                     "precondition: the new prompt arrives as an append")
        scene.coordinator.update(
            nodes: grown, atBottom: .constant(false), activityToggleToken: 0, linkRoot: "")

        #expect(scene.coordinator.pendingJumpAnchor?.id == target.id)
        #expect(scene.coordinator.heldJumpTargetID == target.id)
        #expect(scene.coordinator.promptEntries.count == Self.promptCount + 1)
        #expect(scene.coordinator.activePromptIndex == 20)
        let firstFrame = scene.screenOffset(ofRow: target.rowIndex)
        #expect(abs(firstFrame - offsetBefore) <= 1,
                Comment(rawValue: "the append moved the target: before=\(offsetBefore) after=\(firstFrame)"))

        await Self.settleJump(scene)

        let settled = scene.screenOffset(ofRow: target.rowIndex)
        #expect(abs(settled - offsetBefore) <= 1,
                Comment(rawValue: "the target moved once the append settled: before=\(offsetBefore) after=\(settled)"))
        #expect(scene.coordinator.pendingJumpAnchor?.id == target.id)
    }

    @Test("a prepend and a width change each release the jump anchor")
    func prependAndWidthChangeRelease() async throws {
        let suiteName = "prompt-rail-jump-release-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: Self.promptCount, replySentences: Self.tallReplies)
        let scene = Self.primedAtEnd(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        let entries = scene.coordinator.promptEntries
        try #require(entries.count == Self.promptCount)
        let primedWidth = scene.tableView.bounds.width

        // Prepend: earlier history lands at the front while the jump is held.
        scene.coordinator.jump(toNodeID: entries[20].id)
        await Self.settleJump(scene)
        try #require(scene.coordinator.pendingJumpAnchor != nil)
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

        #expect(scene.coordinator.pendingJumpAnchor == nil)
        #expect(scene.coordinator.heldJumpTargetID == nil)
        // The prepend holds the reader's place with its own anchor instead, and
        // a jump moves the reader away from it, so a jump supersedes it.
        try #require(scene.coordinator.pendingPrependAnchor != nil)
        let shifted = scene.coordinator.promptEntries
        try #require(shifted.first?.rowIndex == 2)
        scene.coordinator.jump(toNodeID: shifted[30].id)
        #expect(scene.coordinator.pendingPrependAnchor == nil)

        // Width change. The resize moves the clip's bounds, which may already
        // release the hold through the bounds observer; jump again afterwards
        // so only the update's width-change path can release it.
        scene.scrollView.frame = NSRect(
            x: 0, y: 0, width: TableTranscriptScene.width - 120, height: TableTranscriptScene.viewportHeight)
        scene.settle()
        try #require(scene.tableView.bounds.width < primedWidth - 60,
                     Comment(rawValue: "precondition: the column narrowed (\(scene.tableView.bounds.width) pt)"))
        scene.coordinator.jump(toNodeID: shifted[30].id)
        try #require(scene.coordinator.pendingJumpAnchor != nil)

        // Same nodes and the same prepend token: only the width moved.
        scene.coordinator.update(
            nodes: prepended, atBottom: .constant(false), activityToggleToken: 0, linkRoot: "",
            prependToken: 1)

        #expect(scene.coordinator.pendingJumpAnchor == nil)
        #expect(scene.coordinator.heldJumpTargetID == nil)
    }

    @Test("a jump to an unknown id leaves the scroll and any held jump alone")
    func unknownIDLeavesScroll() async throws {
        let suiteName = "prompt-rail-jump-unknown-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: Self.promptCount, replySentences: Self.tallReplies)
        let scene = Self.primedAtEnd(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        let entries = scene.coordinator.promptEntries
        try #require(entries.count == Self.promptCount)
        let clip = scene.scrollView.contentView

        scene.park(row: entries[20].rowIndex, below: 100)
        let parked = clip.bounds.minY
        scene.coordinator.jump(toNodeID: "nope")
        #expect(clip.bounds.minY == parked)
        #expect(scene.coordinator.pendingJumpAnchor == nil)
        #expect(scene.coordinator.heldJumpTargetID == nil)

        scene.coordinator.jump(toNodeID: entries[30].id)
        await Self.settleJump(scene)
        let jumped = clip.bounds.minY
        scene.coordinator.jump(toNodeID: "nope")
        #expect(clip.bounds.minY == jumped)
        #expect(scene.coordinator.heldJumpTargetID == entries[30].id)
        #expect(scene.coordinator.pendingJumpAnchor?.id == entries[30].id)
    }

    /// The last prompts cannot be scrolled to the top. The jump clamps at the
    /// end, and the held target, not the bottom rule, decides what is active.
    @Test("a jump near the end clamps at the bottom and holds its target active")
    func jumpNearEndHoldsTarget() async throws {
        let suiteName = "prompt-rail-jump-end-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        // Short replies on the last two exchanges, so both fit in the last screen.
        let items = PromptRailFixtures.conversation(
            prompts: Self.promptCount, replySentences: { $0 >= 58 ? 3 : Self.tallReplies($0) })
        let scene = Self.primedAtEnd(items: items, appState: appState)
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
        #expect(scene.coordinator.heldJumpTargetID == nil)
        #expect(scene.coordinator.activePromptIndex == 59)
    }

    @Test("previous and next step through the prompts")
    func previousNextSemantics() async throws {
        let suiteName = "prompt-rail-jump-steps-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: Self.promptCount, replySentences: Self.tallReplies)
        let scene = Self.primedAtEnd(items: items, appState: appState)
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
        coordinator.jumpToPrompt(.previous)
        #expect(clip.bounds.minY == atFirst)
        #expect(coordinator.activePromptIndex == 0)

        // From the last prompt, Next scrolls to the end and stops holding it.
        coordinator.jump(toNodeID: entries[59].id)
        await Self.settleJump(scene)
        coordinator.jumpToPrompt(.next)
        #expect(scene.gapToBottom <= 1, Comment(rawValue: "Next from the last prompt left \(scene.gapToBottom) pt"))
        #expect(coordinator.heldJumpTargetID == nil)
        #expect(coordinator.pendingJumpAnchor == nil)

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
        let scene = Self.primedAtEnd(items: items, appState: appState)
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
        #expect(scene.coordinator.heldJumpTargetID == nil)

        scene.coordinator.jumpToPrompt(.next)
        #expect(scene.coordinator.heldJumpTargetID == entries[0].id)
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
        let scene = Self.primedAtEnd(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        try #require(scene.coordinator.promptEntries.isEmpty)
        let clip = scene.scrollView.contentView
        scene.park(row: 10, below: 0)
        let origin = clip.bounds.minY

        scene.coordinator.jumpToPrompt(.previous)
        scene.coordinator.jumpToPrompt(.next)

        #expect(clip.bounds.minY == origin)
        #expect(scene.coordinator.heldJumpTargetID == nil)
        #expect(scene.coordinator.pendingJumpAnchor == nil)
    }
}
