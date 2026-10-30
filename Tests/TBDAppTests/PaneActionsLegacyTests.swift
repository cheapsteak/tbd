import Foundation
import SwiftUI
import Testing
import TBDShared

@testable import TBDApp

// Tier 1: the legacy pane action set against an in-memory layout and an
// isolated AppState. Each action is checked against the shared routing
// function it wraps, so the rollback path stays pinned to the behaviour
// `PanePlaceholder` had when it mutated the layout itself.

/// The layout the action set reads and writes through its binding. A
/// `@MainActor` class rather than a captured local `var`, so the binding's
/// closures capture a Sendable reference.
@MainActor
private final class LayoutBox {
    var value: LayoutNode

    init(_ value: LayoutNode) {
        self.value = value
    }

    var binding: Binding<LayoutNode> {
        Binding(get: { self.value }, set: { self.value = $0 })
    }
}

@MainActor
private struct LegacyFixture {
    let state: AppState
    let box: LayoutBox
    let worktree: LocalWorktree
    let actions: PaneActions
}

@Suite("PaneActions legacy")
@MainActor
struct PaneActionsLegacyTests {
    private func withFixture(
        _ layout: LayoutNode,
        _ body: (LegacyFixture) throws -> Void
    ) throws {
        let suiteName = "TBDAppTests.PaneActionsLegacy-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(userDefaults: defaults)
        let worktree = try #require(LocalWorktree(Worktree(
            repoID: UUID(), name: "wt", displayName: "WT", branch: "main",
            path: "/tmp/acme-wt", tmuxServer: "test-server")))
        let box = LayoutBox(layout)
        let actions = PaneActions.legacy(
            layout: box.binding, appState: state, worktree: worktree)
        try body(LegacyFixture(state: state, box: box, worktree: worktree, actions: actions))
    }

    private static func split(_ first: PaneContent, _ second: PaneContent) -> LayoutNode {
        .split(id: UUID(), direction: .horizontal, children: [.pane(first), .pane(second)], ratios: [0.5, 0.5])
    }

    // MARK: - Routing

    @Test func routeTerminalFileMatchesRouteFileClick() throws {
        let terminalID = UUID()
        let slotID = UUID()
        let outgoing = PaneContent.codeViewer(id: slotID, path: "/a.swift")
        let initial = Self.split(.terminal(terminalID: terminalID), outgoing)

        try withFixture(initial) { fixture in
            fixture.actions.routeTerminalFile(terminalID, "/b.swift")

            let expected = routeFileClick(into: initial, terminalID: terminalID, path: "/b.swift")
            #expect(fixture.box.value == expected.layout)
            let incoming = PaneContent.codeViewer(id: slotID, path: "/b.swift")
            #expect(fixture.state.paneHistories[slotID]?.entries == [incoming, outgoing])
        }
    }

    @Test func navigateInPaneMatchesRouteInPaneFileNavigation() throws {
        let slotID = UUID()
        let outgoing = PaneContent.codeViewer(id: slotID, path: "/docs/a.md")
        let initial = Self.split(.terminal(terminalID: UUID()), outgoing)

        try withFixture(initial) { fixture in
            fixture.actions.navigateInPane(outgoing, "/docs/b.md")

            let expected = try #require(
                routeInPaneFileNavigation(into: initial, paneID: slotID, path: "/docs/b.md"))
            #expect(fixture.box.value == expected.layout)
            let incoming = PaneContent.codeViewer(id: slotID, path: "/docs/b.md")
            let recorded = fixture.state.paneHistories[slotID]
            #expect(recorded?.entries == [incoming, outgoing])

            // Navigating to the file already shown is a no-op: no layout
            // write, no duplicate history entry.
            let before = fixture.box.value
            fixture.actions.navigateInPane(incoming, "/docs/b.md")
            #expect(fixture.box.value == before)
            #expect(fixture.state.paneHistories[slotID] == recorded)
        }
    }

    @Test func openTranscriptLinkFileMatchesRouteFileClick() throws {
        let terminalID = UUID()
        let transcript = PaneContent.liveTranscript(id: UUID(), terminalID: terminalID)
        let initial = Self.split(.terminal(terminalID: terminalID), transcript)

        try withFixture(initial) { fixture in
            fixture.actions.openTranscriptLink(transcript, terminalID, .file("/src/c.swift"))

            let expected = routeFileClick(into: initial, terminalID: terminalID, path: "/src/c.swift")
            #expect(fixture.box.value == expected.layout)
            #expect(fixture.state.paneHistories[transcript.paneID]?.entries.last == transcript)
        }
    }

    @Test func openFilePreviewSplitsBeside() throws {
        let transcript = PaneContent.liveTranscript(id: UUID(), terminalID: UUID())

        try withFixture(.pane(transcript)) { fixture in
            fixture.actions.openFilePreview(transcript, "/src/d.swift")

            guard case .split(_, let direction, let children, let ratios) = fixture.box.value else {
                Issue.record("expected a split, got \(fixture.box.value)")
                return
            }
            #expect(direction == .horizontal)
            #expect(ratios == [0.5, 0.5])
            #expect(children.count == 2)
            #expect(children.first == .pane(transcript))
            guard case .pane(.codeViewer(_, let path))? = children.last else {
                Issue.record("expected a code viewer beside the transcript, got \(children)")
                return
            }
            #expect(path == "/src/d.swift")
            // A split adds a pane; it replaces nothing, so no history moves.
            #expect(fixture.state.paneHistories.isEmpty)
        }
    }

    // MARK: - Transcript toggle

    @Test func toggleTranscriptOpensThenRestoresPriorContent() throws {
        let terminalID = UUID()
        let terminal = PaneContent.terminal(terminalID: terminalID)
        let viewer = PaneContent.codeViewer(id: UUID(), path: "/a.swift")
        let initial = Self.split(terminal, viewer)

        try withFixture(initial) { fixture in
            #expect(!fixture.actions.isTranscriptOpen(terminalID))

            fixture.actions.toggleTranscript(terminal, terminalID)
            let opened = TBDShared.toggleTranscript(into: initial, terminalID: terminalID, fromPaneID: terminalID)
            #expect(fixture.box.value == opened.layout)
            #expect(fixture.actions.isTranscriptOpen(terminalID))

            // Toggling off restores the slot's pre-transcript content in place
            // rather than removing the pane.
            fixture.actions.toggleTranscript(terminal, terminalID)
            #expect(fixture.box.value == initial)
            #expect(!fixture.actions.isTranscriptOpen(terminalID))
        }
    }

    // MARK: - History

    @Test func historyStepWritesHistoryThenLayout() throws {
        let terminalID = UUID()
        let slotID = UUID()
        let first = PaneContent.codeViewer(id: slotID, path: "/a.swift")
        let second = PaneContent.codeViewer(id: slotID, path: "/b.swift")
        let initial = Self.split(.terminal(terminalID: terminalID), first)

        try withFixture(initial) { fixture in
            fixture.actions.routeTerminalFile(terminalID, "/b.swift")
            let slotContent = { fixture.box.value.firstPaneContent(where: { $0.paneID == slotID }) }
            #expect(slotContent() == second)

            fixture.actions.historyStep(second, .back)
            #expect(fixture.state.paneHistories[slotID]?.cursor == 1)
            #expect(fixture.box.value == initial)

            fixture.actions.historyStep(first, .forward)
            #expect(fixture.state.paneHistories[slotID]?.cursor == 0)
            #expect(slotContent() == second)

            fixture.actions.historyStep(second, .jump(1))
            #expect(fixture.state.paneHistories[slotID]?.cursor == 1)
            #expect(slotContent() == first)
        }
    }

    /// The step reads the recorded history only. The single-entry history the
    /// chevrons display for a never-navigated slot is not one it can step.
    @Test func historyStepWithoutRecordedHistoryDoesNothing() throws {
        let viewer = PaneContent.codeViewer(id: UUID(), path: "/a.swift")
        let initial = Self.split(.terminal(terminalID: UUID()), viewer)

        try withFixture(initial) { fixture in
            fixture.actions.historyStep(viewer, .back)
            fixture.actions.historyStep(viewer, .jump(0))
            #expect(fixture.box.value == initial)
            #expect(fixture.state.paneHistories.isEmpty)
        }
    }

    @Test func historyIsNilForNonViewerContent() throws {
        let terminal = PaneContent.terminal(terminalID: UUID())
        let viewer = PaneContent.codeViewer(id: UUID(), path: "/a.swift")

        try withFixture(.pane(terminal)) { fixture in
            #expect(fixture.actions.history(terminal) == nil)
            #expect(fixture.actions.history(.note(noteID: UUID())) == nil)
            // The gate is the content's class, not the absence of a record.
            fixture.state.paneHistories[terminal.paneID] = PaneHistory.seeded(with: terminal)
            #expect(fixture.actions.history(terminal) == nil)

            // A viewer that never navigated shows a history seeded with its
            // current content; once it has a record, the record wins.
            #expect(fixture.actions.history(viewer) == PaneHistory.seeded(with: viewer))
            var recorded = PaneHistory()
            recorded.recordReplacement(
                outgoing: viewer, incoming: .codeViewer(id: viewer.paneID, path: "/b.swift"))
            fixture.state.paneHistories[viewer.paneID] = recorded
            #expect(fixture.actions.history(viewer) == recorded)
        }
    }

    // MARK: - Close

    @Test func closeRemovesThePaneAndItsHistory() throws {
        let terminal = PaneContent.terminal(terminalID: UUID())
        let viewer = PaneContent.codeViewer(id: UUID(), path: "/a.swift")

        try withFixture(Self.split(terminal, viewer)) { fixture in
            let tabs = [TBDShared.Tab(id: terminal.paneID, content: terminal)]
            fixture.state.tabs[fixture.worktree.id] = tabs
            fixture.state.paneHistories[viewer.paneID] = PaneHistory.seeded(with: viewer)

            fixture.actions.close(viewer)

            #expect(fixture.box.value == .pane(terminal))
            #expect(fixture.state.paneHistories[viewer.paneID] == nil)
            #expect(fixture.state.tabs[fixture.worktree.id] == tabs)
        }
    }

    @Test func closeLastPaneRemovesTheTab() throws {
        let terminal = PaneContent.terminal(terminalID: UUID())
        let initial = LayoutNode.pane(terminal)

        try withFixture(initial) { fixture in
            let other = TBDShared.Tab(id: UUID(), content: .terminal(terminalID: UUID()))
            let closing = TBDShared.Tab(id: terminal.paneID, content: terminal)
            fixture.state.tabs[fixture.worktree.id] = [other, closing]
            fixture.state.layouts[closing.id] = initial

            fixture.actions.close(terminal)

            #expect(fixture.state.tabs[fixture.worktree.id] == [other])
            #expect(fixture.state.layouts[closing.id] == nil)
            // The last pane goes with its tab; the binding itself is not
            // written.
            #expect(fixture.box.value == initial)
        }
    }

    @Test func canCloseIsAlwaysTrue() throws {
        let contents: [PaneContent] = [
            .terminal(terminalID: UUID()),
            .webview(id: UUID(), url: URL(string: "https://example.com")!),
            .codeViewer(id: UUID(), path: "/a.swift"),
            .note(noteID: UUID()),
            .liveTranscript(id: UUID(), terminalID: UUID()),
        ]

        try withFixture(.pane(contents[0])) { fixture in
            for content in contents {
                #expect(fixture.actions.canClose(content))
            }
        }
    }
}
