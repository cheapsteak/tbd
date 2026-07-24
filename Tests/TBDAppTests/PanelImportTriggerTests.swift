import Foundation
import Testing
import TBDShared
@testable import TBDApp

// Spec C §11.2 — the app-side half of the gated legacy panel import.
// DaemonClient is a concrete class (no protocol), so the trigger's RPC call
// is exercised through the same injectable-closure seam other AppState tests
// use (`daemonCapabilitiesFetcher`, `controlModeSetter`, ...): `panelImportTrigger`.

@Suite("Panel import trigger")
@MainActor
struct PanelImportTriggerTests {

    // MARK: - buildPanelImportParams (pure)

    @Test func buildPanelImportParamsExcludesStaleWorktreeKeyedGridEntry() {
        let suiteName = "PanelImportTriggerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(userDefaults: defaults)
        let worktreeID = UUID()
        let tabID = UUID()
        let terminalID = UUID()
        state.tabs[worktreeID] = [TBDShared.Tab(id: tabID, content: .terminal(terminalID: terminalID), label: "T1")]
        state.layouts[tabID] = .pane(.terminal(terminalID: terminalID))
        // Pollution: a stale worktree-keyed entry (pre-#478 grid state), not
        // any real tab's ID — must never be sent as a tab payload.
        state.layouts[worktreeID] = .pane(.codeViewer(id: UUID(), path: "/stale-grid"))

        let params = state.buildPanelImportParams(worktreeID: worktreeID)

        #expect(params.tabs.count == 1)
        #expect(params.tabs.first?.tabID == tabID)
        #expect(params.tabs.allSatisfy { $0.tabID != worktreeID },
                "the stale worktree-keyed layouts entry must never surface as a tab payload")
    }

    @Test func buildPanelImportParamsFiltersOrphanedPaneHistories() {
        let suiteName = "PanelImportTriggerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(userDefaults: defaults)
        let worktreeID = UUID()
        let tabID = UUID()
        let liveSlotID = UUID()
        let orphanSlotID = UUID()
        state.tabs[worktreeID] = [TBDShared.Tab(id: tabID, content: .terminal(terminalID: tabID), label: nil)]
        state.layouts[tabID] = .split(
            id: UUID(), direction: .horizontal,
            children: [.pane(.terminal(terminalID: tabID)), .pane(.codeViewer(id: liveSlotID, path: "/a"))],
            ratios: [0.5, 0.5]
        )
        var history = PaneHistory()
        history.recordReplacement(
            outgoing: .codeViewer(id: liveSlotID, path: "/old"),
            incoming: .codeViewer(id: liveSlotID, path: "/a")
        )
        state.paneHistories = [liveSlotID: history, orphanSlotID: history]

        let params = state.buildPanelImportParams(worktreeID: worktreeID)

        #expect(params.paneHistories[liveSlotID] != nil, "history for a slot in the included layout must flow through")
        #expect(params.paneHistories[orphanSlotID] == nil, "orphaned histories must be dropped at the import boundary")
    }

    @Test func buildPanelImportParamsFlowsLabelOrderAndActiveTab() {
        let suiteName = "PanelImportTriggerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(userDefaults: defaults)
        let worktreeID = UUID()
        let tabA = TBDShared.Tab(id: UUID(), content: .terminal(terminalID: UUID()), label: "Alpha")
        let tabB = TBDShared.Tab(id: UUID(), content: .terminal(terminalID: UUID()), label: "Beta")
        state.tabs[worktreeID] = [tabA, tabB]
        state.worktreeTabOrders[worktreeID] = [tabB.id, tabA.id]
        state.activeTabIndices[worktreeID] = 1

        let params = state.buildPanelImportParams(worktreeID: worktreeID)

        #expect(params.tabOrder == [tabB.id, tabA.id])
        #expect(params.activeTabID == tabB.id)
        #expect(params.tabs.first(where: { $0.tabID == tabA.id })?.label == "Alpha")
        #expect(params.tabs.first(where: { $0.tabID == tabB.id })?.label == "Beta")
    }

    // MARK: - Trigger gating

    @Test func flagOffFiresNoImportCall() async {
        let suiteName = "PanelImportTriggerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(userDefaults: defaults)
        state.daemonCapabilities = DaemonCapabilitiesResult(controlModeEnabled: false, panelSurfaceEnabled: false)
        var calls: [PanelImportParams] = []
        state.panelImportTrigger = { params in
            calls.append(params)
            return PanelImportResult(imported: true, tabCount: 0, promotedTerminalTabs: 0, skipped: [])
        }
        state.tabs[UUID()] = [TBDShared.Tab(id: UUID(), content: .terminal(terminalID: UUID()), label: nil)]

        state.triggerPanelImportIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(calls.isEmpty, "flag off must not call panel.importLegacy")
    }

    @Test func flagUnknownCapabilitiesFiresNoImportCall() async {
        // Capabilities not yet fetched (nil) must behave like flag-off, not
        // opt in by accident.
        let suiteName = "PanelImportTriggerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(userDefaults: defaults)
        #expect(state.daemonCapabilities == nil)
        var calls: [PanelImportParams] = []
        state.panelImportTrigger = { params in
            calls.append(params)
            return PanelImportResult(imported: true, tabCount: 0, promotedTerminalTabs: 0, skipped: [])
        }
        state.tabs[UUID()] = [TBDShared.Tab(id: UUID(), content: .terminal(terminalID: UUID()), label: nil)]

        state.triggerPanelImportIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(calls.isEmpty, "nil capabilities must not call panel.importLegacy")
    }

    @Test func flagOnFiresImportOnceAcrossRepeatedCalls() async {
        let suiteName = "PanelImportTriggerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(userDefaults: defaults)
        state.daemonCapabilities = DaemonCapabilitiesResult(controlModeEnabled: false, panelSurfaceEnabled: true)
        var calls: [PanelImportParams] = []
        state.panelImportTrigger = { params in
            calls.append(params)
            return PanelImportResult(imported: true, tabCount: params.tabs.count, promotedTerminalTabs: 0, skipped: [])
        }
        let worktreeID = UUID()
        let tabID = UUID()
        state.tabs[worktreeID] = [TBDShared.Tab(id: tabID, content: .terminal(terminalID: tabID), label: nil)]

        state.triggerPanelImportIfNeeded()
        state.triggerPanelImportIfNeeded() // must be a no-op — already attempted this launch

        var recorded = false
        for _ in 0..<200 {
            if !calls.isEmpty { recorded = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorded, "flag on must fire panel.importLegacy")
        #expect(calls.count == 1, "import must fire at most once per launch")
        #expect(calls.first?.worktreeID == worktreeID)
    }

    /// End-to-end wiring check: `loadTabStates` (the real call site) must
    /// still reach the trigger at its tail even when the underlying
    /// `listTabs` RPC fails (no daemon in the test environment) — the import
    /// depends on AppState's already-loaded in-memory state, not on this
    /// particular RPC's success.
    @Test func loadTabStatesFiresImportOnceWhenFlagOn() async {
        let suiteName = "PanelImportTriggerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(userDefaults: defaults)
        state.daemonCapabilities = DaemonCapabilitiesResult(controlModeEnabled: false, panelSurfaceEnabled: true)
        var calls: [PanelImportParams] = []
        state.panelImportTrigger = { params in
            calls.append(params)
            return PanelImportResult(imported: true, tabCount: params.tabs.count, promotedTerminalTabs: 0, skipped: [])
        }
        let worktreeID = UUID()
        let tabID = UUID()
        state.tabs[worktreeID] = [TBDShared.Tab(id: tabID, content: .terminal(terminalID: tabID), label: nil)]

        await state.loadTabStates(worktreeID: worktreeID)
        await state.loadTabStates(worktreeID: worktreeID) // second worktree-load must not re-fire

        var recorded = false
        for _ in 0..<200 {
            if !calls.isEmpty { recorded = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorded, "loadTabStates must reach the import trigger")
        #expect(calls.count == 1, "import must fire at most once per launch")
        #expect(calls.first?.worktreeID == worktreeID)
    }
}
