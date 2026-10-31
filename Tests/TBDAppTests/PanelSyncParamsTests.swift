import Foundation
import Testing
import TBDShared
@testable import TBDApp
import TestSupport

/// `AppState.buildPanelSyncParams` — the `panel.syncTabs` payload built from
/// the app's in-memory tabs, legacy layouts and pane histories. Pure: no RPC,
/// no daemon. A sync deletes the surface of every tab it does not list, so
/// the nil-versus-empty distinction is the contract most worth pinning.
@MainActor
@Suite("Panel sync params")
struct PanelSyncParamsTests {
    private func withAppState(_ body: (AppState) throws -> Void) throws {
        let suite = TestDefaultsSuite("tbd-panel-sync-params")
        defer { suite.tearDown() }
        try body(AppState(userDefaults: suite.defaults))
    }

    @Test func unloadedTabListBuildsNoParams() throws {
        try withAppState { state in
            let worktreeID = UUID()
            #expect(state.tabs[worktreeID] == nil)
            #expect(state.buildPanelSyncParams(worktreeID: worktreeID) == nil,
                    "a worktree whose tabs are not loaded must never sync as an empty list")
        }
    }

    @Test func loadedEmptyTabListBuildsEmptyParams() throws {
        try withAppState { state in
            let worktreeID = UUID()
            state.tabs[worktreeID] = []

            let params = try #require(state.buildPanelSyncParams(worktreeID: worktreeID))

            #expect(params.worktreeID == worktreeID)
            #expect(params.tabs.isEmpty)
            #expect(params.paneHistories.isEmpty)
        }
    }

    @Test func tabsFlowInTabBarOrderWithLabelContentAndLayout() throws {
        try withAppState { state in
            let worktreeID = UUID()
            let alpha = TBDShared.Tab(id: UUID(), content: .terminal(terminalID: UUID()), label: "Alpha")
            let beta = TBDShared.Tab(id: UUID(), content: .terminal(terminalID: UUID()), label: "Beta")
            let betaLayout = LayoutNode.split(
                id: UUID(), direction: .horizontal,
                children: [.pane(beta.content), .pane(.codeViewer(id: UUID(), path: "/b"))],
                ratios: [0.5, 0.5])
            state.tabs[worktreeID] = [beta, alpha]
            state.layouts[beta.id] = betaLayout

            let params = try #require(state.buildPanelSyncParams(worktreeID: worktreeID))

            #expect(params.tabs.map(\.tabID) == [beta.id, alpha.id])
            #expect(params.tabs.map(\.label) == ["Beta", "Alpha"])
            #expect(params.tabs.map(\.content) == [beta.content, alpha.content])
            #expect(params.tabs.first?.layout == betaLayout)
            #expect(params.tabs.last?.layout == nil)
        }
    }

    @Test func staleWorktreeKeyedGridEntryIsNeverSent() throws {
        try withAppState { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let terminalID = UUID()
            state.tabs[worktreeID] = [TBDShared.Tab(id: tabID, content: .terminal(terminalID: terminalID), label: "T1")]
            state.layouts[tabID] = .pane(.terminal(terminalID: terminalID))
            // Pollution: a stale worktree-keyed entry (pre-#478 grid state),
            // not any real tab's ID — must never be sent as a tab payload.
            state.layouts[worktreeID] = .pane(.codeViewer(id: UUID(), path: "/stale-grid"))

            let params = try #require(state.buildPanelSyncParams(worktreeID: worktreeID))

            #expect(params.tabs.map(\.tabID) == [tabID])
        }
    }

    @Test func orphanedPaneHistoriesAreDropped() throws {
        try withAppState { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let liveSlotID = UUID()
            let orphanSlotID = UUID()
            state.tabs[worktreeID] = [TBDShared.Tab(id: tabID, content: .terminal(terminalID: tabID), label: nil)]
            state.layouts[tabID] = .split(
                id: UUID(), direction: .horizontal,
                children: [.pane(.terminal(terminalID: tabID)), .pane(.codeViewer(id: liveSlotID, path: "/a"))],
                ratios: [0.5, 0.5])
            var history = PaneHistory()
            history.recordReplacement(
                outgoing: .codeViewer(id: liveSlotID, path: "/old"),
                incoming: .codeViewer(id: liveSlotID, path: "/a"))
            state.paneHistories = [liveSlotID: history, orphanSlotID: history]

            let params = try #require(state.buildPanelSyncParams(worktreeID: worktreeID))

            #expect(params.paneHistories[liveSlotID] != nil, "a slot in an included layout keeps its history")
            #expect(params.paneHistories[orphanSlotID] == nil, "an orphaned history is dropped at the sync boundary")
        }
    }
}
