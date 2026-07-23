import Foundation
import Testing
import TBDShared
@testable import TBDApp

// Spec C §11.3 — the pure shadow-compare comparator. Migration-validation
// diagnostic only: exercises `PanelShadowCompare.mismatches` directly, no
// AppState/daemon involved (the impure trigger wiring lives in AppState and
// is covered by PanelImportTriggerTests-style injection, not here).

@Suite("PanelShadowCompare")
struct ShadowCompareTests {
    private let worktreeID = UUID()

    private func surface(
        id: UUID, primary: PrimaryContent, label: String? = nil,
        layout: PanelLayoutNode = .primary, revision: UInt64 = 0
    ) -> WorkspaceTabSurface {
        WorkspaceTabSurface(id: id, worktreeID: worktreeID, label: label, primary: primary, layout: layout, revision: revision)
    }

    @Test func identicalConversionAndGetProduceNoMismatches() {
        let tabID = UUID()
        let terminalID = UUID()
        let tab = surface(id: tabID, primary: .terminal(terminalID: terminalID), label: "Alpha")
        let local = LegacySurfaceImporter.Conversion(surfaces: [tab])
        let daemon = PanelGetResult(tabs: [tab], activeTabID: nil)

        #expect(PanelShadowCompare.mismatches(local: local, daemon: daemon).isEmpty)
    }

    @Test func revisionDifferenceAloneIsNotReported() {
        let tabID = UUID()
        let terminalID = UUID()
        let localTab = surface(id: tabID, primary: .terminal(terminalID: terminalID), label: "Alpha", revision: 0)
        let daemonTab = surface(id: tabID, primary: .terminal(terminalID: terminalID), label: "Alpha", revision: 7)
        let local = LegacySurfaceImporter.Conversion(surfaces: [localTab])
        let daemon = PanelGetResult(tabs: [daemonTab], activeTabID: nil)

        #expect(PanelShadowCompare.mismatches(local: local, daemon: daemon).isEmpty,
                "daemon may have advanced the revision — that alone is not a divergence")
    }

    @Test func differingLayoutReportsOneMismatchNamingTheTab() {
        let tabID = UUID()
        let terminalID = UUID()
        let viewerID = UUID()
        let localTab = surface(id: tabID, primary: .terminal(terminalID: terminalID), layout: .primary)
        let daemonLayout = PanelLayoutNode.split(SplitNode(
            id: UUID(), direction: .horizontal,
            children: [.primary, .panel(PanelSlot(id: viewerID, content: .file(FileReference(path: "/a"))))],
            ratios: [0.5, 0.5]))
        let daemonTab = surface(id: tabID, primary: .terminal(terminalID: terminalID), layout: daemonLayout)
        let local = LegacySurfaceImporter.Conversion(surfaces: [localTab])
        let daemon = PanelGetResult(tabs: [daemonTab], activeTabID: nil)

        let mismatches = PanelShadowCompare.mismatches(local: local, daemon: daemon)

        #expect(mismatches.count == 1)
        #expect(mismatches.first?.contains(tabID.uuidString) == true)
    }

    @Test func daemonExtraTabIsReported() {
        // Import-order drift: the daemon already imported a tab on a prior
        // launch that the current live legacy state no longer has (e.g. the
        // app closed it locally since); create-if-absent import means the
        // daemon surface is never retroactively pruned.
        let sharedTabID = UUID()
        let terminalID = UUID()
        let extraTabID = UUID()
        let sharedTab = surface(id: sharedTabID, primary: .terminal(terminalID: terminalID))
        let extraDaemonTab = surface(id: extraTabID, primary: .terminal(terminalID: UUID()))
        let local = LegacySurfaceImporter.Conversion(surfaces: [sharedTab])
        let daemon = PanelGetResult(tabs: [sharedTab, extraDaemonTab], activeTabID: nil)

        let mismatches = PanelShadowCompare.mismatches(local: local, daemon: daemon)

        #expect(mismatches.count == 1)
        #expect(mismatches.first?.contains(extraTabID.uuidString) == true)
    }

    @Test func localExtraTabIsReported() {
        let sharedTabID = UUID()
        let terminalID = UUID()
        let extraLocalTabID = UUID()
        let sharedTab = surface(id: sharedTabID, primary: .terminal(terminalID: terminalID))
        let extraLocalTab = surface(id: extraLocalTabID, primary: .terminal(terminalID: UUID()))
        let local = LegacySurfaceImporter.Conversion(surfaces: [sharedTab, extraLocalTab])
        let daemon = PanelGetResult(tabs: [sharedTab], activeTabID: nil)

        let mismatches = PanelShadowCompare.mismatches(local: local, daemon: daemon)

        #expect(mismatches.count == 1)
        #expect(mismatches.first?.contains(extraLocalTabID.uuidString) == true)
    }

    @Test func importerTransformsAreNotFlagged_terminalPromotionRatioRepairViewerToPanel() {
        // The trigger builds `local` by running the SAME `LegacySurfaceImporter.convert`
        // the daemon's import used — so terminal-leaf promotion, ratio repair, and
        // viewer-leaf-to-panel conversion are already baked into `local`, not raw legacy
        // state. Simulate the daemon side as exactly what that conversion produced
        // (what a correct import would return) and confirm none of those legitimate
        // transforms register as a mismatch.
        let tabID = UUID()
        let primaryTerminalID = UUID()
        let extraTerminalID = UUID()
        let viewerID = UUID()
        let malformedRatioLayout = LayoutNode.split(
            id: UUID(), direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: primaryTerminalID)),
                .pane(.terminal(terminalID: extraTerminalID)),
                .pane(.codeViewer(id: viewerID, path: "/a")),
            ],
            ratios: [-1, 0, 999] // deliberately malformed — importer repairs to equal shares
        )
        let payload = LegacyTabPayload(
            tabID: tabID, label: "Mixed", content: .terminal(terminalID: primaryTerminalID),
            layout: malformedRatioLayout)

        let conversion = LegacySurfaceImporter.convert(
            worktreeID: worktreeID, tabs: [payload], tabOrder: [tabID], paneHistories: [:])

        // Sanity: the importer really did promote the extra terminal and repair ratios.
        #expect(conversion.promotedTerminalTabs == 1)
        #expect(conversion.surfaces.count == 2)

        let daemon = PanelGetResult(tabs: conversion.surfaces, activeTabID: nil)

        #expect(PanelShadowCompare.mismatches(local: conversion, daemon: daemon).isEmpty,
                "importer's own transforms (promotion, ratio repair, viewer→panel) must never be flagged")
    }

    @Test func labelMismatchIsReported() {
        let tabID = UUID()
        let terminalID = UUID()
        let localTab = surface(id: tabID, primary: .terminal(terminalID: terminalID), label: "Old")
        let daemonTab = surface(id: tabID, primary: .terminal(terminalID: terminalID), label: "New")
        let local = LegacySurfaceImporter.Conversion(surfaces: [localTab])
        let daemon = PanelGetResult(tabs: [daemonTab], activeTabID: nil)

        let mismatches = PanelShadowCompare.mismatches(local: local, daemon: daemon)

        #expect(mismatches.count == 1)
        #expect(mismatches.first?.contains(tabID.uuidString) == true)
    }
}

// MARK: - AppState wiring (spec C §11.3's "runs once after import" half)

/// Exercises `AppState.triggerPanelImportIfNeeded`'s shadow-compare hook via
/// the same injectable-closure seam `PanelImportTriggerTests` uses for the
/// import RPC itself (`panelImportTrigger`) — `panelGetFetcher` here.
@Suite("PanelShadowCompare AppState wiring")
@MainActor
struct ShadowCompareTriggerTests {

    @Test func flagOnCallsPanelGetAfterSuccessfulImport() async {
        let suiteName = "ShadowCompareTriggerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(userDefaults: defaults)
        state.daemonCapabilities = DaemonCapabilitiesResult(controlModeEnabled: false, panelSurfaceEnabled: true)
        state.panelImportTrigger = { params in
            PanelImportResult(imported: true, tabCount: params.tabs.count, promotedTerminalTabs: 0, skipped: [])
        }
        var getCalls: [UUID] = []
        state.panelGetFetcher = { worktreeID in
            getCalls.append(worktreeID)
            return PanelGetResult(tabs: [], activeTabID: nil)
        }
        let worktreeID = UUID()
        let tabID = UUID()
        state.tabs[worktreeID] = [TBDShared.Tab(id: tabID, content: .terminal(terminalID: tabID), label: nil)]

        state.triggerPanelImportIfNeeded()

        var recorded = false
        for _ in 0..<200 {
            if !getCalls.isEmpty { recorded = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorded, "shadow compare must fetch panel.get after a successful import")
        #expect(getCalls == [worktreeID])
    }

    @Test func importedFalseStillRunsShadowCompare() async {
        // "after a successful import (or imported == false)" — the daemon
        // already having a surface (create-if-absent no-op) must still run
        // the comparison, not just a fresh import.
        let suiteName = "ShadowCompareTriggerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(userDefaults: defaults)
        state.daemonCapabilities = DaemonCapabilitiesResult(controlModeEnabled: false, panelSurfaceEnabled: true)
        state.panelImportTrigger = { params in
            PanelImportResult(imported: false, tabCount: params.tabs.count, promotedTerminalTabs: 0, skipped: [])
        }
        var getCalls: [UUID] = []
        state.panelGetFetcher = { worktreeID in
            getCalls.append(worktreeID)
            return PanelGetResult(tabs: [], activeTabID: nil)
        }
        let worktreeID = UUID()
        state.tabs[worktreeID] = [TBDShared.Tab(id: UUID(), content: .terminal(terminalID: UUID()), label: nil)]

        state.triggerPanelImportIfNeeded()

        var recorded = false
        for _ in 0..<200 {
            if !getCalls.isEmpty { recorded = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorded, "imported == false must still run the shadow compare")
    }

    @Test func importFailureSkipsShadowCompare() async {
        let suiteName = "ShadowCompareTriggerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(userDefaults: defaults)
        state.daemonCapabilities = DaemonCapabilitiesResult(controlModeEnabled: false, panelSurfaceEnabled: true)
        struct Boom: Error {}
        state.panelImportTrigger = { _ in throw Boom() }
        var getCalls: [UUID] = []
        state.panelGetFetcher = { worktreeID in
            getCalls.append(worktreeID)
            return PanelGetResult(tabs: [], activeTabID: nil)
        }
        let worktreeID = UUID()
        state.tabs[worktreeID] = [TBDShared.Tab(id: UUID(), content: .terminal(terminalID: UUID()), label: nil)]

        state.triggerPanelImportIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(getCalls.isEmpty, "a failed import must not run the shadow compare")
    }

    @Test func flagOffNeverCallsPanelGet() async {
        let suiteName = "ShadowCompareTriggerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(userDefaults: defaults)
        state.daemonCapabilities = DaemonCapabilitiesResult(controlModeEnabled: false, panelSurfaceEnabled: false)
        state.panelImportTrigger = { params in
            PanelImportResult(imported: true, tabCount: params.tabs.count, promotedTerminalTabs: 0, skipped: [])
        }
        var getCalls: [UUID] = []
        state.panelGetFetcher = { worktreeID in
            getCalls.append(worktreeID)
            return PanelGetResult(tabs: [], activeTabID: nil)
        }
        state.tabs[UUID()] = [TBDShared.Tab(id: UUID(), content: .terminal(terminalID: UUID()), label: nil)]

        state.triggerPanelImportIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(getCalls.isEmpty, "flag off must not run the shadow compare either")
    }

    @Test func shadowCompareNeverMutatesAppState() async {
        // Log-only: even when the comparator finds real mismatches, AppState's
        // own tab/layout/history state must be untouched.
        let suiteName = "ShadowCompareTriggerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(userDefaults: defaults)
        state.daemonCapabilities = DaemonCapabilitiesResult(controlModeEnabled: false, panelSurfaceEnabled: true)
        state.panelImportTrigger = { params in
            PanelImportResult(imported: true, tabCount: params.tabs.count, promotedTerminalTabs: 0, skipped: [])
        }
        state.panelGetFetcher = { _ in
            // Deliberately divergent from local state — forces mismatches.
            PanelGetResult(
                tabs: [WorkspaceTabSurface(
                    id: UUID(), worktreeID: UUID(), label: "unexpected",
                    primary: .terminal(terminalID: UUID()), layout: .primary, revision: 0)],
                activeTabID: nil)
        }
        let worktreeID = UUID()
        let tabID = UUID()
        state.tabs[worktreeID] = [TBDShared.Tab(id: tabID, content: .terminal(terminalID: tabID), label: "T1")]
        let tabsBefore = state.tabs
        let layoutsBefore = state.layouts
        let paneHistoriesBefore = state.paneHistories

        state.triggerPanelImportIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))

        #expect(state.tabs == tabsBefore)
        #expect(state.layouts == layoutsBefore)
        #expect(state.paneHistories == paneHistoriesBefore)
    }
}
