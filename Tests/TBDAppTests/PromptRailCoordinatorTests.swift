import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// The transcript table coordinator's prompt-rail tracking, driven headlessly in
/// `TableTranscriptScene`: the outline follows the nodes, the active prompt
/// follows the clip, the presenter hears only changes, and none of it builds or
/// measures a cell.
@Suite("Prompt rail coordinator")
@MainActor
struct PromptRailCoordinatorTests {
    /// Replies of 12–20 sentences, so every exchange is taller than the 120pt
    /// probe band of the 600pt viewport: with a prompt parked 40pt below the
    /// viewport top, the next prompt sits below the probe line.
    nonisolated private static func tallReplies(_ index: Int) -> Int { 12 + (index * 5) % 9 }

    @MainActor
    private final class RecordingPresenter: PromptRailPresenter {
        var entryLists: [[PromptOutlineEntry]] = []
        var activeIndices: [Int?] = []

        func promptRail(entriesDidChange entries: [PromptOutlineEntry]) {
            entryLists.append(entries)
        }

        func promptRail(activeIndexDidChange index: Int?) {
            activeIndices.append(index)
        }
    }

    /// Counts the cells AppKit asks the coordinator to build.
    private final class CellCountingCoordinator: TableTranscriptView.Coordinator {
        var viewForCalls = 0

        override func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            viewForCalls += 1
            return super.tableView(tableView, viewFor: tableColumn, row: row)
        }
    }

    @Test("the outline follows an appended prompt and the presenter hears it once")
    func outlineFollowsAppends() throws {
        let suiteName = "prompt-rail-append-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: 5, replySentences: Self.tallReplies)
        let scene = TableTranscriptScene(items: items, appState: appState)
        let presenter = RecordingPresenter()
        defer { withExtendedLifetime(scene.coordinator) {} }
        defer { withExtendedLifetime(presenter) {} }
        scene.coordinator.startObservingScroll()
        scene.coordinator.promptRailPresenter = presenter
        scene.prime(nodes: transcriptRenderNodes(from: items))

        #expect(scene.coordinator.promptEntries.map(\.id) == (0..<5).map { "p-\($0)" })
        // The empty list pushed on attach, then the outline once: priming's
        // repeated width-change updates rebuild the same outline and stay quiet.
        #expect(presenter.entryLists.map(\.count) == [0, 5])

        let grown = items + [.userPrompt(id: "p-5", text: "Prompt 5", timestamp: nil)]
        scene.coordinator.update(
            nodes: transcriptRenderNodes(from: grown), atBottom: .constant(true),
            activityToggleToken: 0, linkRoot: "")

        #expect(scene.coordinator.promptEntries.count == 6)
        #expect(presenter.entryLists.count == 3,
                Comment(rawValue: "the append must deliver exactly one new list "
                    + "(lists: \(presenter.entryLists.map(\.count)))"))
        #expect(presenter.entryLists.last == scene.coordinator.promptEntries)
    }

    /// A streaming tick re-renders only the last row. Rebuilding the outline on
    /// every tick would re-read every prompt for nothing, so `.updateLast`
    /// rebuilds it only when the last row is a prompt.
    @Test("a streamed reply leaves the outline alone; a re-rendered trailing prompt rebuilds it")
    func updateLastRebuildsOutlineOnlyForAPrompt() throws {
        let suiteName = "prompt-rail-updatelast-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: 5, replySentences: Self.tallReplies)
        let scene = TableTranscriptScene(items: items, appState: appState)
        let presenter = RecordingPresenter()
        defer { withExtendedLifetime(scene.coordinator) {} }
        defer { withExtendedLifetime(presenter) {} }
        scene.coordinator.startObservingScroll()
        scene.prime(nodes: transcriptRenderNodes(from: items))
        let entries = scene.coordinator.promptEntries
        try #require(entries.count == 5)
        scene.coordinator.promptRailPresenter = presenter

        // Equal outlines never notify, so a rebuild would be invisible. Seed a
        // stale outline one entry short: a rebuild then shows up as a new list.
        scene.coordinator.promptEntries = Array(entries.dropLast())
        let listsBeforeReply = presenter.entryLists.count

        var streamed = items
        streamed[streamed.count - 1] = .assistantText(
            id: "a-4",
            text: String(repeating: "A reply sentence whose prose wraps across the column. ", count: 30),
            timestamp: nil,
            usage: nil)
        let streamedNodes = transcriptRenderNodes(from: streamed)
        try #require(TranscriptStreamPlan.step(previous: scene.coordinator.previousNodes, next: streamedNodes)
                         == .updateLast,
                     "precondition: the grown reply arrives as a tail re-render")
        scene.coordinator.update(
            nodes: streamedNodes, atBottom: .constant(false), activityToggleToken: 0, linkRoot: "")

        #expect(presenter.entryLists.count == listsBeforeReply,
                Comment(rawValue: "a streamed reply rebuilt the outline (lists: \(presenter.entryLists.map(\.count)))"))
        #expect(scene.coordinator.promptEntries.count == 4)

        // A trailing prompt arrives (an append rebuilds the outline), then
        // re-renders with new text.
        let withPrompt = streamed + [.userPrompt(id: "p-5", text: "Prompt 5", timestamp: nil)]
        scene.coordinator.update(
            nodes: transcriptRenderNodes(from: withPrompt), atBottom: .constant(false),
            activityToggleToken: 0, linkRoot: "")
        try #require(scene.coordinator.promptEntries.count == 6)
        let listsBeforeEdit = presenter.entryLists.count

        var edited = withPrompt
        edited[edited.count - 1] = .userPrompt(id: "p-5", text: "Prompt 5, edited", timestamp: nil)
        let editedNodes = transcriptRenderNodes(from: edited)
        try #require(TranscriptStreamPlan.step(previous: scene.coordinator.previousNodes, next: editedNodes)
                         == .updateLast,
                     "precondition: the edited prompt arrives as a tail re-render")
        scene.coordinator.update(
            nodes: editedNodes, atBottom: .constant(false), activityToggleToken: 0, linkRoot: "")

        #expect(presenter.entryLists.count == listsBeforeEdit + 1)
        #expect(scene.coordinator.promptEntries.last?.firstLine == "Prompt 5, edited")
    }

    @Test("the active prompt follows the scroll position")
    func activeFollowsScroll() throws {
        let suiteName = "prompt-rail-scroll-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: 30, replySentences: Self.tallReplies)
        let scene = TableTranscriptScene(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        scene.coordinator.startObservingScroll()
        scene.prime(nodes: transcriptRenderNodes(from: items))
        let entries = scene.coordinator.promptEntries
        try #require(entries.count == 30)

        scene.park(row: entries[12].rowIndex, below: 40)
        #expect(scene.coordinator.activePromptIndex == 12)

        scene.scroll(toY: .greatestFiniteMagnitude)
        #expect(scene.gapToBottom <= 1, "precondition: the clip reached the end")
        #expect(scene.coordinator.activePromptIndex == 29)
    }

    @Test("scrolling inside one exchange tells the presenter nothing new")
    func scrollWithinOneExchangeNotifiesOnce() throws {
        let suiteName = "prompt-rail-steady-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: 30, replySentences: Self.tallReplies)
        let scene = TableTranscriptScene(items: items, appState: appState)
        let presenter = RecordingPresenter()
        defer { withExtendedLifetime(scene.coordinator) {} }
        defer { withExtendedLifetime(presenter) {} }
        scene.coordinator.startObservingScroll()
        scene.prime(nodes: transcriptRenderNodes(from: items))
        let entries = scene.coordinator.promptEntries
        try #require(entries.count == 30)
        scene.coordinator.promptRailPresenter = presenter
        let notificationsBeforePark = presenter.activeIndices.count

        scene.park(row: entries[12].rowIndex, below: 40)
        #expect(presenter.activeIndices.count == notificationsBeforePark + 1)
        #expect(presenter.activeIndices.last == 12)

        // Scroll down 10pt at a time until just before prompt 13's top would
        // cross the probe line, so the reader stays inside exchange 12.
        let clip = scene.scrollView.contentView
        let origin = clip.bounds.minY
        let probe = PromptRailActiveRule.probeFraction * clip.bounds.height
        let room = scene.screenOffset(ofRow: entries[13].rowIndex) - probe
        try #require(room > 30, Comment(rawValue: "fixture: exchange 12 leaves too little room (\(room) pt)"))
        var offset: CGFloat = 10
        while offset < room {
            scene.scroll(toY: origin + offset)
            offset += 10
        }
        #expect(clip.bounds.minY > origin + 20, "precondition: the clip moved")
        #expect(presenter.activeIndices.count == notificationsBeforePark + 1,
                Comment(rawValue: "scrolling within one exchange notified again: \(presenter.activeIndices)"))
        #expect(scene.coordinator.activePromptIndex == 12)
    }

    @Test("rebuilding the outline and the active prompt builds and measures no cells")
    func outlineAndActiveBuildNoCells() throws {
        let suiteName = "prompt-rail-cells-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        // More rows than the bottom window measures, so the rule's binary search
        // reads row tops that only carry an estimate.
        let items = PromptRailFixtures.conversation(prompts: 30, replySentences: Self.tallReplies)
        let scene = TableTranscriptScene(
            items: items, appState: appState,
            makeCoordinator: { CellCountingCoordinator(context: $0) })
        defer { withExtendedLifetime(scene.coordinator) {} }
        let coordinator = try #require(scene.coordinator as? CellCountingCoordinator)
        coordinator.startObservingScroll()
        scene.prime(nodes: transcriptRenderNodes(from: items))
        try #require(coordinator.nodes.count > TableTranscriptView.Coordinator.bottomEagerWindow)

        let cellsBefore = coordinator.viewForCalls
        let measuredBefore = coordinator.cachedHeightRowCount
        try #require(cellsBefore > 0, "precondition: priming realizes the visible rows, so the counter is live")

        coordinator.refreshPromptOutline()
        coordinator.refreshActivePrompt()

        #expect(coordinator.viewForCalls == cellsBefore)
        #expect(coordinator.cachedHeightRowCount == measuredBefore)
        #expect(coordinator.activePromptIndex == 0)
    }

    @Test("a transcript with no prompts has no entries and no active prompt")
    func zeroPromptsIsEmptyAndNil() throws {
        let suiteName = "prompt-rail-empty-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items: [TranscriptItem] = (0..<6).map { index in
            .assistantText(
                id: "a-\(index)",
                text: String(repeating: "Assistant prose with no prompt anywhere above it. ", count: 10),
                timestamp: nil,
                usage: nil)
        }
        let scene = TableTranscriptScene(items: items, appState: appState)
        let presenter = RecordingPresenter()
        defer { withExtendedLifetime(scene.coordinator) {} }
        defer { withExtendedLifetime(presenter) {} }
        scene.coordinator.startObservingScroll()
        scene.coordinator.promptRailPresenter = presenter
        scene.prime(nodes: transcriptRenderNodes(from: items))
        scene.scroll(toY: .greatestFiniteMagnitude)

        #expect(scene.coordinator.promptEntries.isEmpty)
        #expect(scene.coordinator.activePromptIndex == nil)
        // Only the values pushed on attach: nothing changed after that.
        #expect(presenter.entryLists == [[]])
        #expect(presenter.activeIndices == [nil])
    }

    @Test("when every prompt fits on the last screen, the last one is active")
    func allPromptsOnLastScreenPicksLast() throws {
        let suiteName = "prompt-rail-onescreen-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: 3, replySentences: { _ in 3 })
        let scene = TableTranscriptScene(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        scene.coordinator.startObservingScroll()
        scene.prime(nodes: transcriptRenderNodes(from: items))
        // Priming's own update must already pick the last prompt, so the
        // update hook is pinned and not only the manual refresh below.
        #expect(scene.coordinator.activePromptIndex == 2,
                "the update hook did not pick the last prompt")
        // Re-read against the settled layout rather than the one priming's
        // update saw.
        scene.coordinator.refreshActivePrompt()

        let entries = scene.coordinator.promptEntries
        try #require(entries.count == 3)
        let lastRow = scene.tableView.rect(ofRow: entries[2].rowIndex)
        let probe = PromptRailActiveRule.probeFraction * TableTranscriptScene.viewportHeight
        #expect(scene.tableView.rect(ofRow: scene.tableView.numberOfRows - 1).maxY
                    <= TableTranscriptScene.viewportHeight,
                "precondition: the whole transcript fits on one screen")
        #expect(lastRow.minY > probe,
                "precondition: the last prompt sits below the probe line, so only the bottom rule picks it")
        #expect(scene.coordinator.activePromptIndex == 2)
    }

    /// A streamed tick grows the last reply below the viewport, and the
    /// tail-follow catches up a main-queue turn later. In between the clip is
    /// off the bottom, where the probe rule would hand the active notch from
    /// the last prompt to the one before it for that turn.
    @Test("streaming at the bottom never moves the active prompt off the last one")
    func streamingAtBottomKeepsLastActive() async throws {
        let suiteName = "prompt-rail-streaming-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        // Tall exchanges, then a short last one, so at the bottom the last
        // prompt sits low on screen and only the bottom rule makes it active.
        var items = PromptRailFixtures.conversation(
            prompts: 30, replySentences: { $0 == 29 ? 2 : Self.tallReplies($0) })
        let scene = TableTranscriptScene(items: items, appState: appState)
        let presenter = RecordingPresenter()
        defer { withExtendedLifetime(scene.coordinator) {} }
        defer { withExtendedLifetime(presenter) {} }
        scene.coordinator.startObservingScroll()
        scene.prime(nodes: transcriptRenderNodes(from: items))
        scene.scroll(toY: .greatestFiniteMagnitude)
        scene.settle()
        scene.scroll(toY: .greatestFiniteMagnitude)
        try #require(scene.gapToBottom <= 1, Comment(rawValue: "precondition: at the end (gap \(scene.gapToBottom) pt)"))
        let entries = scene.coordinator.promptEntries
        try #require(entries.count == 30)
        let probe = PromptRailActiveRule.probeFraction * TableTranscriptScene.viewportHeight
        let lastTop = scene.screenOffset(ofRow: entries[29].rowIndex)
        try #require(lastTop > probe + 200,
                     Comment(rawValue: "precondition: the last prompt sits well below the probe line, so the "
                         + "probe rule alone would pick the one before it (top \(lastTop) pt)"))
        try #require(scene.coordinator.activePromptIndex == 29)
        scene.coordinator.promptRailPresenter = presenter

        for tick in 1...4 {
            items[items.count - 1] = .assistantText(
                id: "a-29",
                text: String(repeating: "A reply sentence whose prose wraps across the column. ", count: 2 + 3 * tick),
                timestamp: nil,
                usage: nil)
            let nodes = transcriptRenderNodes(from: items)
            try #require(TranscriptStreamPlan.step(previous: scene.coordinator.previousNodes, next: nodes)
                             == .updateLast,
                         "precondition: the tick arrives as a tail re-render")
            scene.coordinator.update(nodes: nodes, atBottom: .constant(true), activityToggleToken: 0, linkRoot: "")
            scene.tableView.layoutSubtreeIfNeeded()
            try #require(scene.gapToBottom > PromptRailActiveRule.bottomSlack,
                         Comment(rawValue: "precondition: tick \(tick) grew the reply below the viewport, so the "
                             + "clip is off the bottom until the tail-follow runs (gap \(scene.gapToBottom) pt)"))
            // AppKit can post a bounds change while it lays the grown row out.
            NotificationCenter.default.post(
                name: NSView.boundsDidChangeNotification, object: scene.scrollView.contentView)
            await drainMainQueue()
            #expect(scene.gapToBottom <= 1,
                    Comment(rawValue: "tick \(tick): the tail-follow did not reach the end (gap \(scene.gapToBottom) pt)"))
        }

        // Only the value pushed on attach: the last prompt stayed active.
        #expect(presenter.activeIndices == [29],
                Comment(rawValue: "the active prompt left the last one while streaming: \(presenter.activeIndices)"))
    }

    @Test("attaching a presenter pushes the current outline and active prompt")
    func attachingPresenterPushesCurrentState() throws {
        let suiteName = "prompt-rail-attach-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: 5, replySentences: Self.tallReplies)
        let scene = TableTranscriptScene(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        scene.coordinator.startObservingScroll()
        scene.prime(nodes: transcriptRenderNodes(from: items))
        try #require(!scene.coordinator.promptEntries.isEmpty)

        let presenter = RecordingPresenter()
        defer { withExtendedLifetime(presenter) {} }
        scene.coordinator.promptRailPresenter = presenter

        #expect(presenter.entryLists == [scene.coordinator.promptEntries])
        #expect(presenter.activeIndices == [scene.coordinator.activePromptIndex])
    }

    @Test("a held jump target stays active; an unknown or cleared one falls back to the rule")
    func heldJumpTargetWins() throws {
        let suiteName = "prompt-rail-held-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: 30, replySentences: Self.tallReplies)
        let scene = TableTranscriptScene(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        scene.coordinator.startObservingScroll()
        scene.prime(nodes: transcriptRenderNodes(from: items))
        let entries = scene.coordinator.promptEntries
        try #require(entries.count == 30)
        scene.park(row: entries[12].rowIndex, below: 40)
        try #require(scene.coordinator.activePromptIndex == 12)

        scene.coordinator.heldJumpTargetID = entries[3].id
        scene.coordinator.refreshActivePrompt()
        #expect(scene.coordinator.activePromptIndex == 3)

        scene.coordinator.heldJumpTargetID = "a-3"  // a reply, not an entry
        scene.coordinator.refreshActivePrompt()
        #expect(scene.coordinator.activePromptIndex == 12)

        scene.coordinator.heldJumpTargetID = entries[3].id
        scene.coordinator.refreshActivePrompt()
        scene.coordinator.heldJumpTargetID = nil
        scene.coordinator.refreshActivePrompt()
        #expect(scene.coordinator.activePromptIndex == 12)
    }

    /// Rows can move under the table before `refreshPromptOutline()` runs — a
    /// clip-bounds change posted from inside `update(...)`'s table ops reaches
    /// `refreshActivePrompt()` first. Its index would be read off rows the
    /// entries no longer name, so it must wait for the rebuild.
    @Test("an outline that no longer names its rows waits for the rebuild")
    func staleOutlineWaitsForRebuild() throws {
        let suiteName = "prompt-rail-stale-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let items = PromptRailFixtures.conversation(prompts: 30, replySentences: Self.tallReplies)
        let scene = TableTranscriptScene(items: items, appState: appState)
        let presenter = RecordingPresenter()
        defer { withExtendedLifetime(scene.coordinator) {} }
        defer { withExtendedLifetime(presenter) {} }
        scene.coordinator.startObservingScroll()
        scene.prime(nodes: transcriptRenderNodes(from: items))
        let entries = scene.coordinator.promptEntries
        try #require(entries.count == 30)
        scene.park(row: entries[12].rowIndex, below: 40)
        try #require(scene.coordinator.activePromptIndex == 12)
        scene.coordinator.promptRailPresenter = presenter
        let notifications = presenter.activeIndices.count

        // Two tall rows land at the front and the table reloads, but the
        // outline has not been rebuilt: every entry's row index is now two
        // rows short, pointing at rows hundreds of points lower down.
        let front: [TranscriptItem] = (0..<2).map { index in
            .assistantText(
                id: "front-\(index)",
                text: String(repeating: "Earlier history arriving above the reader. ", count: 40),
                timestamp: nil,
                usage: nil)
        }
        scene.coordinator.nodes = transcriptRenderNodes(from: front + items)
        scene.tableView.reloadData()
        scene.coordinator.refreshActivePrompt()

        #expect(presenter.activeIndices.count == notifications,
                Comment(rawValue: "an index read off shifted rows reached the presenter: \(presenter.activeIndices)"))
        #expect(scene.coordinator.activePromptIndex == 12)

        scene.coordinator.refreshPromptOutline()
        #expect(scene.coordinator.promptEntries.first?.rowIndex == 2)
        #expect(presenter.entryLists.last == scene.coordinator.promptEntries)
    }
}
