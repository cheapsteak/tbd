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

    @Test func selectTab_throwsNotTabScoped() {
        #expect(throws: PanelOperationError.notTabScoped) {
            _ = try PanelSurfaceReducer.apply(.selectTab(tabID: UUID()), to: bareState())
        }
    }
}
