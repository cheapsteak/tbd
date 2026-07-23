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

    /// A tab exercising BOTH of `LegacySurfaceImporter`'s `makeID()` mint
    /// sites at once: an extra terminal leaf (promotion mints a new surface
    /// id) and a note leaf (mints a new panel slot id). Plus a codeViewer
    /// leaf whose id is caller-supplied and stable — the one piece of real
    /// content this helper can vary to prove genuine divergence still shows.
    private func mixedPayload(
        tabID: UUID, primaryTerminalID: UUID, extraTerminalID: UUID, noteID: UUID,
        viewerLegacyID: UUID, viewerPath: String
    ) -> LegacyTabPayload {
        let layout = LayoutNode.split(
            id: UUID(), direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: primaryTerminalID)),
                .pane(.terminal(terminalID: extraTerminalID)),
                .pane(.note(noteID: noteID)),
                .pane(.codeViewer(id: viewerLegacyID, path: viewerPath)),
            ],
            ratios: [0.25, 0.25, 0.25, 0.25])
        return LegacyTabPayload(
            tabID: tabID, label: "Mixed", content: .terminal(terminalID: primaryTerminalID), layout: layout)
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
        // Matching key for a terminal-primary tab is the stable terminalID,
        // not the (possibly minted) surface id.
        #expect(mismatches.first?.contains(terminalID.uuidString) == true)
    }

    @Test func daemonExtraTabIsReported() {
        // Import-order drift: the daemon already imported a tab on a prior
        // launch that the current live legacy state no longer has (e.g. the
        // app closed it locally since); create-if-absent import means the
        // daemon surface is never retroactively pruned.
        let sharedTerminalID = UUID()
        let extraTerminalID = UUID()
        let sharedTab = surface(id: UUID(), primary: .terminal(terminalID: sharedTerminalID))
        let extraDaemonTab = surface(id: UUID(), primary: .terminal(terminalID: extraTerminalID))
        let local = LegacySurfaceImporter.Conversion(surfaces: [sharedTab])
        let daemon = PanelGetResult(tabs: [sharedTab, extraDaemonTab], activeTabID: nil)

        let mismatches = PanelShadowCompare.mismatches(local: local, daemon: daemon)

        #expect(mismatches.count == 1)
        #expect(mismatches.first?.contains(extraTerminalID.uuidString) == true)
    }

    @Test func localExtraTabIsReported() {
        let sharedTerminalID = UUID()
        let extraTerminalID = UUID()
        let sharedTab = surface(id: UUID(), primary: .terminal(terminalID: sharedTerminalID))
        let extraLocalTab = surface(id: UUID(), primary: .terminal(terminalID: extraTerminalID))
        let local = LegacySurfaceImporter.Conversion(surfaces: [sharedTab, extraLocalTab])
        let daemon = PanelGetResult(tabs: [sharedTab], activeTabID: nil)

        let mismatches = PanelShadowCompare.mismatches(local: local, daemon: daemon)

        #expect(mismatches.count == 1)
        #expect(mismatches.first?.contains(extraTerminalID.uuidString) == true)
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
        #expect(mismatches.first?.contains(terminalID.uuidString) == true)
    }

    // MARK: - Independent-conversion mutation killers (the real trigger shape)

    /// THE core regression test: `local` and `daemon` here are NOT the same
    /// value reused twice — they come from two SEPARATE, independent
    /// `LegacySurfaceImporter.convert` calls on identical legacy input,
    /// exactly like production (the daemon converted once at import; this
    /// diagnostic converts again later). Each call mints its OWN random IDs
    /// at both `makeID()` sites (promoted-tab surface id, note panel slot
    /// id) — a comparator that matches/compares by minted id instead of
    /// stable content would report spurious mismatches here on virtually
    /// every real launch that has a note panel or a multi-terminal tab.
    @Test func independentConvertsOfIdenticalLegacyState_noSpuriousMismatches() {
        let tabID = UUID()
        let primaryTerminalID = UUID()
        let extraTerminalID = UUID()
        let noteID = UUID()
        let viewerLegacyID = UUID()
        let payload = mixedPayload(
            tabID: tabID, primaryTerminalID: primaryTerminalID, extraTerminalID: extraTerminalID,
            noteID: noteID, viewerLegacyID: viewerLegacyID, viewerPath: "/a")

        let local = LegacySurfaceImporter.convert(
            worktreeID: worktreeID, tabs: [payload], tabOrder: [tabID], paneHistories: [:])
        let daemonConversion = LegacySurfaceImporter.convert(
            worktreeID: worktreeID, tabs: [payload], tabOrder: [tabID], paneHistories: [:])

        // Sanity: this really does exercise two independent random draws —
        // otherwise the test proves nothing.
        #expect(local.promotedTerminalTabs == 1)
        #expect(daemonConversion.promotedTerminalTabs == 1)
        #expect(local.surfaces[1].id != daemonConversion.surfaces[1].id,
                "test setup must produce two genuinely independent minted promoted-tab ids")

        let daemon = PanelGetResult(tabs: daemonConversion.surfaces, activeTabID: nil)
        let mismatches = PanelShadowCompare.mismatches(local: local, daemon: daemon)

        #expect(mismatches.isEmpty,
                "two independent conversions of identical legacy state must never diverge on minted ids alone")
    }

    /// Companion to the above: ID-normalization must not swallow REAL
    /// divergence. Two independent conversions of legacy input that differs
    /// in one meaningful way (a codeViewer's path) must still be reported.
    @Test func independentConvertsWithRealContentDivergence_stillFlagged() {
        let tabID = UUID()
        let primaryTerminalID = UUID()
        let extraTerminalID = UUID()
        let noteID = UUID()
        let viewerLegacyID = UUID()
        let localPayload = mixedPayload(
            tabID: tabID, primaryTerminalID: primaryTerminalID, extraTerminalID: extraTerminalID,
            noteID: noteID, viewerLegacyID: viewerLegacyID, viewerPath: "/a")
        let daemonPayload = mixedPayload(
            tabID: tabID, primaryTerminalID: primaryTerminalID, extraTerminalID: extraTerminalID,
            noteID: noteID, viewerLegacyID: viewerLegacyID, viewerPath: "/b")

        let local = LegacySurfaceImporter.convert(
            worktreeID: worktreeID, tabs: [localPayload], tabOrder: [tabID], paneHistories: [:])
        let daemonConversion = LegacySurfaceImporter.convert(
            worktreeID: worktreeID, tabs: [daemonPayload], tabOrder: [tabID], paneHistories: [:])
        let daemon = PanelGetResult(tabs: daemonConversion.surfaces, activeTabID: nil)

        let mismatches = PanelShadowCompare.mismatches(local: local, daemon: daemon)

        #expect(mismatches.count == 1)
        #expect(mismatches.first?.contains(primaryTerminalID.uuidString) == true,
                "the tab is keyed by its stable terminalID, not a minted id")
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
