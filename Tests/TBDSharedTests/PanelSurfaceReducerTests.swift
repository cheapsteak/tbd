import Foundation
import Testing
@testable import TBDShared

@Suite("PanelSurfaceReducer.openNavigateHistory")
struct PanelSurfaceReducerOpenTests {
    private let primaryTerminal = UUID()

    private func bareState() -> PanelSurfaceState {
        PanelSurfaceState(
            surface: WorkspaceTabSurface(
                id: UUID(), worktreeID: UUID(),
                primary: .terminal(terminalID: primaryTerminal),
                layout: .primary, revision: 0),
            histories: [:])
    }
    private func file(_ p: String) -> PanelContent { .file(FileReference(path: p)) }

    @Test func openAutomatic_onBareTab_splitsRightOfPrimaryAt35() throws {
        let out = try PanelSurfaceReducer.apply(
            .open(content: file("/a"), placement: .automatic), to: bareState())
        guard case .split(let split) = out.surface.layout else {
            Issue.record("expected split"); return
        }
        #expect(split.direction == .horizontal)
        #expect(split.children.count == 2)
        #expect(split.children[0] == .primary)
        #expect(split.ratios == [0.65, 0.35])
        let panelID = out.surface.layout.allPanelIDs[0]
        #expect(out.histories[panelID]?.entries == [file("/a")], "history seeded")
        #expect(out.surface.revision == 1)
        #expect(PanelSurfaceValidator.violations(in: out).isEmpty)
    }

    @Test func openAutomatic_withExistingPanel_navigatesItInPlace() throws {
        let s1 = try PanelSurfaceReducer.apply(
            .open(content: file("/a"), placement: .automatic), to: bareState())
        let panelID = s1.surface.layout.allPanelIDs[0]
        let s2 = try PanelSurfaceReducer.apply(
            .open(content: file("/b"), placement: .automatic), to: s1)
        #expect(s2.surface.layout.allPanelIDs == [panelID], "same slot, same ID")
        #expect(s2.surface.layout.panelSlot(id: panelID)?.content == file("/b"))
        #expect(s2.histories[panelID]?.entries == [file("/b"), file("/a")], "MRU pushed")
    }

    @Test func openBesideUnknownPanel_throwsAnchorNotFound() {
        #expect(throws: PanelOperationError.anchorNotFound) {
            _ = try PanelSurfaceReducer.apply(
                .open(content: file("/a"),
                      placement: .beside(target: .panel(UUID()), edge: .right, share: nil)),
                to: bareState())
        }
    }

    @Test func navigate_toSameContent_isNoOpButBumpsRevision() throws {
        let s1 = try PanelSurfaceReducer.apply(
            .open(content: file("/a"), placement: .automatic), to: bareState())
        let panelID = s1.surface.layout.allPanelIDs[0]
        let s2 = try PanelSurfaceReducer.apply(
            .navigate(panelID: panelID, destination: file("/a")), to: s1)
        #expect(s2.histories[panelID]?.entries == [file("/a")], "no duplicate entry")
        #expect(s2.surface.revision == s1.surface.revision + 1)
    }

    @Test func historyBackForward_moveCursorAndSlotContent() throws {
        var state = try PanelSurfaceReducer.apply(
            .open(content: file("/a"), placement: .automatic), to: bareState())
        let panelID = state.surface.layout.allPanelIDs[0]
        state = try PanelSurfaceReducer.apply(
            .navigate(panelID: panelID, destination: file("/b")), to: state)

        let back = try PanelSurfaceReducer.apply(
            .history(panelID: panelID, action: .back), to: state)
        #expect(back.surface.layout.panelSlot(id: panelID)?.content == file("/a"))
        #expect(back.histories[panelID]?.cursor == 1)
        #expect(back.histories[panelID]?.entries == [file("/b"), file("/a")], "no reorder")

        let fwd = try PanelSurfaceReducer.apply(
            .history(panelID: panelID, action: .forward), to: back)
        #expect(fwd.surface.layout.panelSlot(id: panelID)?.content == file("/b"))

        #expect(throws: PanelOperationError.historyUnavailable(panelID)) {
            _ = try PanelSurfaceReducer.apply(
                .history(panelID: panelID, action: .forward), to: fwd)
        }
    }

    // Base for insertion-branch tests: root horizontal split [primary | A] at [0.6, 0.4].
    private func splitState(rootID: SplitID, panelA: PanelSlot) -> PanelSurfaceState {
        PanelSurfaceState(
            surface: WorkspaceTabSurface(
                id: UUID(), worktreeID: UUID(),
                primary: .terminal(terminalID: primaryTerminal),
                layout: .split(SplitNode(
                    id: rootID, direction: .horizontal,
                    children: [.primary, .panel(panelA)], ratios: [0.6, 0.4])),
                revision: 0),
            histories: [panelA.id: .seeded(with: panelA.content)])
    }

    @Test func openBesideMatchingAxis_splicesAdjacentAndRescalesSiblings() throws {
        let rootID = UUID()
        let panelA = PanelSlot(id: UUID(), content: file("/a"))
        let newID = UUID()
        let out = try PanelSurfaceReducer.apply(
            .open(content: file("/n"),
                  placement: .beside(target: .panel(panelA.id), edge: .right, share: 0.3)),
            to: splitState(rootID: rootID, panelA: panelA),
            makeID: { newID })
        guard case .split(let split) = out.surface.layout else {
            Issue.record("expected split"); return
        }
        // Same split spliced — no extra nesting, sibling order preserved.
        #expect(split.id == rootID)
        #expect(split.direction == .horizontal)
        #expect(split.children == [
            .primary, .panel(panelA), .panel(PanelSlot(id: newID, content: file("/n")))])
        // Exact arithmetic: siblings scaled by (1 - share), new panel gets share.
        #expect(split.ratios == [0.6 * (1 - 0.3), 0.4 * (1 - 0.3), 0.3])
        #expect(out.histories[newID]?.entries == [file("/n")], "history seeded")
        #expect(PanelSurfaceValidator.violations(in: out).isEmpty)
    }

    @Test func openBesideCrossAxis_wrapsAnchorInPlaceLeavingOuterRatiosUntouched() throws {
        let rootID = UUID()
        let panelA = PanelSlot(id: UUID(), content: file("/a"))
        var ids = [UUID(), UUID()]  // makeID order: new panel slot, then wrap split
        let (newPanelID, wrapSplitID) = (ids[0], ids[1])
        let out = try PanelSurfaceReducer.apply(
            .open(content: file("/n"),
                  placement: .beside(target: .panel(panelA.id), edge: .below, share: 0.4)),
            to: splitState(rootID: rootID, panelA: panelA),
            makeID: { ids.removeFirst() })
        guard case .split(let root) = out.surface.layout else {
            Issue.record("expected split"); return
        }
        // Outer split untouched: same ID, direction, ratios; primary still first.
        #expect(root.id == rootID)
        #expect(root.direction == .horizontal)
        #expect(root.ratios == [0.6, 0.4])
        #expect(root.children[0] == .primary)
        // Anchor wrapped in place: vertical pair [A above, new below] at [1-share, share].
        #expect(root.children[1] == .split(SplitNode(
            id: wrapSplitID, direction: .vertical,
            children: [.panel(panelA), .panel(PanelSlot(id: newPanelID, content: file("/n")))],
            ratios: [1 - 0.4, 0.4])))
        #expect(PanelSurfaceValidator.violations(in: out).isEmpty)
    }

    @Test func selectTab_throwsNotTabScoped() {
        #expect(throws: PanelOperationError.notTabScoped) {
            _ = try PanelSurfaceReducer.apply(.selectTab(tabID: UUID()), to: bareState())
        }
    }
}
