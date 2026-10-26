import AppKit
import Observation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// What the table mounts for the prompt rail: the gutter the transcript's
/// container view keeps for each mount, the rail and card it installs, and
/// the rail mounted the way the three transcript panes mount it.
@Suite("Prompt rail mount")
@MainActor
struct PromptRailMountTests {
    @Test("the container keeps the gutter its mount asks for")
    func containerGutterPerMount() {
        #expect(PromptRailMount.rail(earlier: nil).containerGutter == PromptRailLayout.width)
        #expect(PromptRailMount.none.containerGutter == 0)

        let railed = TranscriptContainerView(scrollView: NSScrollView(), leadingGutter: 20)
        railed.frame = NSRect(x: 0, y: 0, width: 680, height: 600)
        railed.layoutSubtreeIfNeeded()
        #expect(railed.scrollView.frame.minX == 20)
        #expect(railed.scrollView.frame.width == 660)
        #expect(railed.scrollView.frame.height == 600)

        let bare = TranscriptContainerView(scrollView: NSScrollView(), leadingGutter: 0)
        bare.frame = NSRect(x: 0, y: 0, width: 680, height: 600)
        bare.layoutSubtreeIfNeeded()
        #expect(bare.scrollView.frame.minX == 0)
        #expect(bare.scrollView.frame.width == 680)
    }

    @Test("the rail fills the gutter below the card, whichever is installed first")
    func containerStacksRailBelowCard() {
        let container = TranscriptContainerView(
            scrollView: NSScrollView(), leadingGutter: PromptRailLayout.width)
        container.frame = NSRect(x: 0, y: 0, width: 680, height: 600)
        let card = NSView()
        let rail = NSView()
        container.cardView = card
        container.railView = rail
        container.layoutSubtreeIfNeeded()

        #expect(rail.frame == NSRect(x: 0, y: 0, width: PromptRailLayout.width, height: 600))
        #expect(container.subviews == [container.scrollView, rail, card])
    }

    /// End to end through the panes' shape: the table mounted directly, with
    /// the pane's identity and overlay on the table itself. The table's view
    /// spans the pane, the gutter sits inside it, and the rail is installed as
    /// the presenter. One arm without earlier history, as the live pane and
    /// Session History mount it, and one with it, as the Remote pane does.
    @Test("a pane-shaped mount keeps the 20pt gutter inside the table and makes its rail the presenter",
          arguments: [false, true])
    func paneShapedMount(withEarlier: Bool) async throws {
        let suiteName = "prompt-rail-pane-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let box = PaneBox()
        let host = Self.hostPane(box: box, defaults: defaults, withEarlier: withEarlier)
        defer { host.tearDown() }
        let container = try await Self.settledContainer(in: host)

        #expect(host.flippedWindowFrame(container).minX == 0)
        #expect(host.flippedWindowFrame(container).width == 680)
        #expect(container.leadingGutter == PromptRailLayout.width)
        #expect(container.scrollView.frame.minX == 20)
        #expect(container.scrollView.frame.width == 660)

        let coordinator = try #require(container.coordinator, "the container has no coordinator")
        let rail = try #require(container.railView as? PromptRailNSView, "the mount installed no rail")
        let card = try #require(container.cardView as? PromptRailCardNSView, "the mount installed no card")
        #expect(coordinator.promptRailPresenter === rail, "the mount did not make its rail the presenter")
        #expect(rail.frame == NSRect(x: 0, y: 0, width: PromptRailLayout.width, height: 600))
        #expect(container.subviews == [container.scrollView, rail, card])
        let delivered = await host.settle { card.rowCount == (withEarlier ? 4 : 3) }
        #expect(delivered, "the card never received the outline (rows: \(card.rowCount))")
        #expect(rail.entries == coordinator.promptEntries)

        if withEarlier {
            let earlier = try #require(container.promptRailEarlier, "the earlier-history state did not reach the card")
            #expect(earlier.hasEarlier)
            earlier.load()
            #expect(box.loads == 1, "the card's load action is not the pane's")
        } else {
            #expect(container.promptRailEarlier == nil)
        }
    }

    /// The panes put their identity on the table, so a session rollover
    /// rebuilds the rail with the table rather than keeping the old one.
    @Test("a new pane identity rebuilds the rail with the table")
    func paneIdentityRebuildsRail() async throws {
        let suiteName = "prompt-rail-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let box = PaneBox()
        let host = Self.hostPane(box: box, defaults: defaults, withEarlier: false)
        defer { host.tearDown() }
        let first = try await Self.settledContainer(in: host)
        let firstRail = try #require(first.railView as? PromptRailNSView)

        box.identity += 1
        let rebuilt = await host.settle {
            let containers = host.descendants(TranscriptContainerView.self)
            return containers.count == 1 && containers[0] !== first
        }
        try #require(rebuilt, "a new identity did not rebuild the table")
        let second = try await Self.settledContainer(in: host)
        let secondRail = try #require(second.railView as? PromptRailNSView, "the rebuilt table has no rail")
        let coordinator = try #require(second.coordinator, "the rebuilt container has no coordinator")

        #expect(secondRail !== firstRail)
        #expect(coordinator.promptRailPresenter === secondRail)
        #expect(second.leadingGutter == PromptRailLayout.width)
    }

    /// Harnesses build the table with no rail: no gutter, no views, no
    /// presenter.
    @Test("the default mount builds the table with no rail, card or gutter")
    func noneMountsNothing() async throws {
        let suiteName = "prompt-rail-none-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)
        let nodes = transcriptRenderNodes(
            from: PromptRailFixtures.conversation(prompts: 3, replySentences: { _ in 2 }))
        let table = TableTranscriptView(
            context: Self.cardContext(appState: appState),
            atBottom: .constant(true),
            scrollToBottomToken: 0,
            activityToggleToken: 0,
            linkRoot: "",
            nodesProvider: { nodes })
        let host = OffscreenHost(root: table, size: NSSize(width: 680, height: 600))
        defer { host.tearDown() }
        let container = try await Self.settledContainer(in: host)

        #expect(container.leadingGutter == 0)
        #expect(container.scrollView.frame.minX == 0)
        #expect(container.scrollView.frame.width == 680)
        #expect(container.railView == nil)
        #expect(container.cardView == nil)
        #expect(container.promptRailEarlier == nil)
        let coordinator = try #require(container.coordinator, "the container has no coordinator")
        #expect(coordinator.promptRailPresenter == nil)
        // The outline is still built, for the keyboard commands.
        let built = await host.settle { coordinator.promptEntries.count == 3 }
        #expect(built, "the coordinator never built the outline (entries: \(coordinator.promptEntries.count))")
        #expect(coordinator.promptEntries.map(\.id) == ["p-0", "p-1", "p-2"])
    }

    private static func cardContext(appState: AppState) -> TranscriptCardContext {
        TranscriptCardContext(
            terminalID: nil,
            openTranscriptOverlay: nil,
            appState: appState,
            linkResolver: nil,
            onLinkClicked: nil)
    }

    /// A pane-shaped body over a table of three prompts.
    private static func hostPane(
        box: PaneBox, defaults: UserDefaults, withEarlier: Bool
    ) -> OffscreenHost<PaneShapedTable> {
        let root = PaneShapedTable(
            box: box,
            context: cardContext(appState: AppState(userDefaults: defaults)),
            nodes: transcriptRenderNodes(
                from: PromptRailFixtures.conversation(prompts: 3, replySentences: { _ in 2 })),
            withEarlier: withEarlier)
        return OffscreenHost(root: root, size: NSSize(width: 680, height: 600))
    }

    /// The host's container once SwiftUI has made and sized it.
    private static func settledContainer<Root: View>(
        in host: OffscreenHost<Root>
    ) async throws -> TranscriptContainerView {
        let laidOut = await host.settle {
            (host.firstDescendant(TranscriptContainerView.self)?.bounds.width ?? 0) > 0
        }
        try #require(laidOut, "the table never mounted and laid out")
        await host.pump(times: 5)
        return try #require(host.firstDescendant(TranscriptContainerView.self))
    }
}

/// What a test drives a pane-shaped body with: its identity, and the loads
/// its earlier-history action has seen.
@MainActor
@Observable
private final class PaneBox {
    var identity = 0
    var loads = 0
}

/// The table as the transcript panes mount it: the rail mounted on the table
/// itself, the pane's identity and a bottom-leading overlay on the table.
private struct PaneShapedTable: View {
    let box: PaneBox
    let context: TranscriptCardContext
    let nodes: [TranscriptRenderNode]
    let withEarlier: Bool

    var body: some View {
        let box = self.box
        let nodes = self.nodes
        let earlier = withEarlier
            ? PromptRailEarlierHistory(hasEarlier: true, load: { box.loads += 1 })
            : nil
        TableTranscriptView(
            context: context,
            atBottom: .constant(true),
            scrollToBottomToken: 0,
            activityToggleToken: 0,
            linkRoot: "",
            nodesProvider: { nodes },
            promptRail: .rail(earlier: earlier))
            .id(box.identity)
            .overlay(alignment: .bottomLeading) {
                Color.clear.frame(width: 1, height: 1)
            }
    }
}
