import AppKit
import Observation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// What the table mounts for the prompt rail: the gutter the transcript's
/// container view keeps for each mount, the rail overlay it installs, and
/// the rail mounted the way the three transcript panes mount it.
@Suite("Prompt rail mount")
@MainActor
struct PromptRailMountTests {
    @Test("the container keeps the gutter its mount asks for")
    func containerGutterPerMount() {
        #expect(PromptRailMount.rail.containerGutter == PromptRailLayout.width)
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

    @Test("the overlay is as wide as the box can grow: 320pt, capped at the pane's width less 24pt, never below the rail")
    func overlayWidthCaps() {
        #expect(PromptRailRowMetrics.overlayWidth(paneWidth: 680) == 320)
        #expect(PromptRailRowMetrics.overlayWidth(paneWidth: 344) == 320)
        #expect(PromptRailRowMetrics.overlayWidth(paneWidth: 300) == 276)
        #expect(PromptRailRowMetrics.overlayWidth(paneWidth: 30) == PromptRailLayout.width)
        #expect(PromptRailRowMetrics.overlayWidth(paneWidth: 0) == PromptRailLayout.width)
    }

    /// The overlay draws over the transcript; only the gutter narrows the
    /// table.
    @Test("the rail overlays the scroll view from the leading edge while the scroll view keeps the gutter")
    func containerStacksRailOverScrollView() {
        let container = TranscriptContainerView(
            scrollView: NSScrollView(), leadingGutter: PromptRailLayout.width)
        container.frame = NSRect(x: 0, y: 0, width: 680, height: 600)
        let rail = NSView()
        container.railView = rail
        container.layoutSubtreeIfNeeded()

        #expect(rail.frame == NSRect(
            x: 0, y: 0, width: PromptRailRowMetrics.overlayWidth(paneWidth: 680), height: 600))
        #expect(container.scrollView.frame.minX == PromptRailLayout.width)
        #expect(container.scrollView.frame.width == 660)
        #expect(container.subviews == [container.scrollView, rail])

        // A narrower pane narrows the overlay with it.
        container.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        container.layoutSubtreeIfNeeded()
        #expect(rail.frame == NSRect(
            x: 0, y: 0, width: PromptRailRowMetrics.overlayWidth(paneWidth: 300), height: 400))
        #expect(container.scrollView.frame.minX == PromptRailLayout.width)
    }

    /// End to end through the panes' shape: the table mounted directly, with
    /// the pane's identity and overlay on the table itself, as the live pane,
    /// Session History and the Remote pane mount it. The table's view spans
    /// the pane, the gutter sits inside it, and the rail is installed as the
    /// presenter.
    @Test("a pane-shaped mount keeps the 20pt gutter inside the table and makes its rail the presenter")
    func paneShapedMount() async throws {
        let suite = TestDefaultsSuite("prompt-rail-pane")
        let defaults = suite.defaults
        defer { suite.tearDown() }
        let box = PaneBox()
        let host = Self.hostPane(box: box, defaults: defaults)
        defer { host.tearDown() }
        let container = try await Self.settledContainer(in: host)

        #expect(host.flippedWindowFrame(container).minX == 0)
        #expect(host.flippedWindowFrame(container).width == 680)
        #expect(container.leadingGutter == PromptRailLayout.width)
        #expect(container.scrollView.frame.minX == 20)
        #expect(container.scrollView.frame.width == 660)

        let coordinator = try #require(container.coordinator, "the container has no coordinator")
        let rail = try #require(container.railView as? PromptRailNSView, "the mount installed no rail")
        #expect(coordinator.promptRailPresenter === rail, "the mount did not make its rail the presenter")
        #expect(rail.frame == NSRect(
            x: 0, y: 0, width: PromptRailRowMetrics.overlayWidth(paneWidth: 680), height: 600))
        #expect(container.subviews == [container.scrollView, rail])
        let delivered = await host.settle { rail.entries.count == 3 }
        #expect(delivered, "the rail never received the outline (entries: \(rail.entries.count))")
        #expect(rail.entries == coordinator.promptEntries)
    }

    /// The panes put their identity on the table, so a session rollover
    /// rebuilds the rail with the table rather than keeping the old one.
    @Test("a new pane identity rebuilds the rail with the table")
    func paneIdentityRebuildsRail() async throws {
        let suite = TestDefaultsSuite("prompt-rail-identity")
        let defaults = suite.defaults
        defer { suite.tearDown() }
        let box = PaneBox()
        let host = Self.hostPane(box: box, defaults: defaults)
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
    @Test("the default mount builds the table with no rail or gutter")
    func noneMountsNothing() async throws {
        let suite = TestDefaultsSuite("prompt-rail-none")
        let defaults = suite.defaults
        defer { suite.tearDown() }
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
    private static func hostPane(box: PaneBox, defaults: UserDefaults) -> OffscreenHost<PaneShapedTable> {
        let root = PaneShapedTable(
            box: box,
            context: cardContext(appState: AppState(userDefaults: defaults)),
            nodes: transcriptRenderNodes(
                from: PromptRailFixtures.conversation(prompts: 3, replySentences: { _ in 2 })))
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

/// What a test drives a pane-shaped body with: its identity.
@MainActor
@Observable
private final class PaneBox {
    var identity = 0
}

/// The table as the transcript panes mount it: the rail mounted on the table
/// itself, the pane's identity and a bottom-leading overlay on the table.
private struct PaneShapedTable: View {
    let box: PaneBox
    let context: TranscriptCardContext
    let nodes: [TranscriptRenderNode]

    var body: some View {
        let nodes = self.nodes
        TableTranscriptView(
            context: context,
            atBottom: .constant(true),
            scrollToBottomToken: 0,
            activityToggleToken: 0,
            linkRoot: "",
            nodesProvider: { nodes },
            promptRail: .rail)
            .id(box.identity)
            .overlay(alignment: .bottomLeading) {
                Color.clear.frame(width: 1, height: 1)
            }
    }
}
