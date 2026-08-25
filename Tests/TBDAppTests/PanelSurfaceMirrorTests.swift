import Foundation
import TBDShared
import Testing

@testable import TBDApp

/// Phase 3b slice 2 — the app-side mirror of the daemon-owned panel surface,
/// its delta reconciliation, and the single `panel.apply` chokepoint.
///
/// Tier 1: deterministic, in-process only. Every daemon hop goes through the
/// injected `panelGetFetcher` / `panelApplyTrigger` closures, so no socket is
/// opened, and every `AppState` gets its own `UserDefaults` suite so the
/// developer's real `TBDApp.plist` is never touched.
@Suite("Panel surface mirror")
@MainActor
struct PanelSurfaceMirrorTests {

    // MARK: - Fixtures

    /// An `AppState` on a throwaway defaults suite, with the render flag set
    /// as requested and the daemon reporting the store flag.
    private static func makeState(
        flagEnabled: Bool?, panelSurfaceEnabled: Bool = true,
        _ body: @MainActor (AppState, UserDefaults) async throws -> Void
    ) async rethrows {
        let suiteName = "PanelSurfaceMirrorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        if let flagEnabled {
            defaults.set(flagEnabled, forKey: AppState.enableDaemonManagedPanelsKey)
        }
        let state = AppState(userDefaults: defaults)
        state.daemonCapabilities = DaemonCapabilitiesResult(
            controlModeEnabled: false, panelSurfaceEnabled: panelSurfaceEnabled)
        // Fail loudly if a test reaches a seam it did not stub.
        state.panelApplyTrigger = { _ in
            Issue.record("unexpected panel.apply")
            throw UnstubbedSeam()
        }
        state.panelGetFetcher = { _ in
            Issue.record("unexpected panel.get")
            throw UnstubbedSeam()
        }
        try await body(state, defaults)
    }

    private struct UnstubbedSeam: Error {}
    private struct ApplyRejected: Error {}

    private static func tab(
        id: UUID, worktreeID: UUID, revision: UInt64, label: String? = nil
    ) -> WorkspaceTabSurface {
        WorkspaceTabSurface(
            id: id, worktreeID: worktreeID, label: label,
            primary: .terminal(terminalID: id), layout: .primary, revision: revision)
    }

    private static func delta(
        worktreeID: UUID, tabs: [WorkspaceTabSurface] = [], removed: [UUID] = [],
        activeTabID: UUID? = nil
    ) -> PanelSurfaceDelta {
        PanelSurfaceDelta(
            worktreeID: worktreeID, tabs: tabs, removedTabIDs: removed,
            activeTabID: activeTabID, originOperationID: nil)
    }

    // MARK: - The flag itself

    @Test("the render flag defaults to OFF")
    func flagDefaultsOff() {
        let suiteName = "PanelSurfaceMirrorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AppState.enableDaemonManagedPanelsDefault == false)
        #expect(AppState.daemonManagedPanelsEnabled(defaults: defaults) == false,
                "an untouched defaults domain must read as off")
    }

    @Test("daemonManagedPanelsActive requires BOTH the render flag and the daemon store flag")
    func activeRequiresBothFlags() async {
        await Self.makeState(flagEnabled: true, panelSurfaceEnabled: true) { state, _ in
            #expect(state.daemonManagedPanelsActive)
        }
        // The one the plan calls out: user opted in, but the surface was
        // never imported, so there is nothing to render.
        await Self.makeState(flagEnabled: true, panelSurfaceEnabled: false) { state, _ in
            #expect(state.daemonManagedPanelsActive == false)
        }
        await Self.makeState(flagEnabled: false, panelSurfaceEnabled: true) { state, _ in
            #expect(state.daemonManagedPanelsActive == false)
        }
        // Capabilities not yet fetched — same as the store being off.
        await Self.makeState(flagEnabled: true, panelSurfaceEnabled: true) { state, _ in
            state.daemonCapabilities = nil
            #expect(state.daemonManagedPanelsActive == false)
        }
    }

    // MARK: - Delta reconciliation

    @Test("flag OFF: a panelSurfaceChanged delta leaves the mirror empty")
    func flagOffDeltaIsInert() async {
        await Self.makeState(flagEnabled: false) { state, _ in
            let worktreeID = UUID()
            state.handleDelta(.panelSurfaceChanged(Self.delta(
                worktreeID: worktreeID,
                tabs: [Self.tab(id: UUID(), worktreeID: worktreeID, revision: 3)],
                activeTabID: UUID())))

            #expect(state.panelSurfaces.isEmpty,
                    "the daemon broadcasts during the store-only soak; the render flag is off")
        }
    }

    @Test("flag ON: a delta upserts tabs, drops removedTabIDs, and sets the active tab")
    func flagOnDeltaReconciles() async {
        await Self.makeState(flagEnabled: true) { state, _ in
            let worktreeID = UUID()
            let keptID = UUID()
            let staleID = UUID()
            let doomedID = UUID()

            state.handleDelta(.panelSurfaceChanged(Self.delta(
                worktreeID: worktreeID,
                tabs: [
                    Self.tab(id: keptID, worktreeID: worktreeID, revision: 1, label: "kept"),
                    Self.tab(id: staleID, worktreeID: worktreeID, revision: 1, label: "old"),
                    Self.tab(id: doomedID, worktreeID: worktreeID, revision: 1),
                ],
                activeTabID: keptID)))

            #expect(state.panelSurfaces[worktreeID]?.tabs.count == 3)
            #expect(state.panelSurfaces[worktreeID]?.activeTabID == keptID)

            // Second delta: update one tab in place, remove another, move the
            // active tab. Untouched tabs survive.
            state.handleDelta(.panelSurfaceChanged(Self.delta(
                worktreeID: worktreeID,
                tabs: [Self.tab(id: staleID, worktreeID: worktreeID, revision: 7, label: "fresh")],
                removed: [doomedID],
                activeTabID: staleID)))

            let tabs = state.panelSurfaces[worktreeID]?.tabs ?? []
            #expect(tabs.count == 2)
            #expect(tabs.contains { $0.id == keptID && $0.label == "kept" },
                    "an unaffected tab must survive an upsert")
            #expect(tabs.contains { $0.id == staleID && $0.revision == 7 && $0.label == "fresh" },
                    "the affected tab is replaced wholesale by the delta's snapshot")
            #expect(tabs.allSatisfy { $0.id != doomedID }, "removedTabIDs must drop the tab")
            #expect(state.panelSurfaces[worktreeID]?.activeTabID == staleID)
        }
    }

    @Test("flag ON: a nil activeTabID means unchanged, not cleared")
    func nilActiveTabIDPreservesSelection() async {
        // The daemon sends activeTabID: nil on EVERY ordinary surface
        // mutation (PanelCoordinator.apply) and fills it only for selectTab
        // and the legacy import. Treating nil as "clear" would blank the
        // selection on every open/close/resize.
        await Self.makeState(flagEnabled: true) { state, _ in
            let worktreeID = UUID()
            let tabID = UUID()
            state.handleDelta(.panelSurfaceChanged(Self.delta(
                worktreeID: worktreeID,
                tabs: [Self.tab(id: tabID, worktreeID: worktreeID, revision: 1)],
                activeTabID: tabID)))

            state.handleDelta(.panelSurfaceChanged(Self.delta(
                worktreeID: worktreeID,
                tabs: [Self.tab(id: tabID, worktreeID: worktreeID, revision: 2)],
                activeTabID: nil)))

            #expect(state.panelSurfaces[worktreeID]?.activeTabID == tabID)
            #expect(state.panelSurfaces[worktreeID]?.tabs.first?.revision == 2)
        }
    }

    @Test("flag ON: removing the active tab clears the selection")
    func removingActiveTabClearsSelection() async {
        await Self.makeState(flagEnabled: true) { state, _ in
            let worktreeID = UUID()
            let tabID = UUID()
            state.handleDelta(.panelSurfaceChanged(Self.delta(
                worktreeID: worktreeID,
                tabs: [Self.tab(id: tabID, worktreeID: worktreeID, revision: 1)],
                activeTabID: tabID)))

            state.handleDelta(.panelSurfaceChanged(
                Self.delta(worktreeID: worktreeID, removed: [tabID])))

            #expect(state.panelSurfaces[worktreeID]?.tabs.isEmpty == true)
            #expect(state.panelSurfaces[worktreeID]?.activeTabID == nil,
                    "the mirror must not point at a tab it no longer holds")
        }
    }

    // MARK: - Revision monotonicity

    @Test("flag ON: a delta carrying an older revision of a tab is dropped")
    func staleDeltaIsDropped() async {
        await Self.makeState(flagEnabled: true) { state, _ in
            let worktreeID = UUID()
            let tabID = UUID()
            state.panelSurfaces[worktreeID] = PanelGetResult(
                tabs: [Self.tab(id: tabID, worktreeID: worktreeID, revision: 9, label: "current")],
                activeTabID: tabID)

            state.handleDelta(.panelSurfaceChanged(Self.delta(
                worktreeID: worktreeID,
                tabs: [Self.tab(id: tabID, worktreeID: worktreeID, revision: 8, label: "stale")])))

            #expect(state.panelSurfaces[worktreeID]?.tabs.first?.label == "current",
                    "revisions are monotonic per tab; a lower one is a late arrival")
            #expect(state.panelSurfaces[worktreeID]?.tabs.first?.revision == 9)
        }
    }

    @Test("flag ON: removedTabIDs removes a tab whatever revision the mirror holds")
    func removalIgnoresRevisions() async {
        await Self.makeState(flagEnabled: true) { state, _ in
            let worktreeID = UUID()
            let tabID = UUID()
            state.panelSurfaces[worktreeID] = PanelGetResult(
                tabs: [Self.tab(id: tabID, worktreeID: worktreeID, revision: 40)],
                activeTabID: tabID)

            state.handleDelta(.panelSurfaceChanged(Self.delta(
                worktreeID: worktreeID, removed: [tabID])))

            #expect(state.panelSurfaces[worktreeID]?.tabs.isEmpty == true,
                    "the revision guard applies to content, never to removal")
        }
    }

    @Test("a panel.get that resolved behind a newer delta cannot revert that tab")
    func staleGetDoesNotRevertANewerTab() async {
        await Self.makeState(flagEnabled: true) { state, _ in
            let worktreeID = UUID()
            let racedID = UUID()
            let untouchedID = UUID()
            let goneID = UUID()
            state.panelSurfaces[worktreeID] = PanelGetResult(
                tabs: [
                    // A delta committed rev 11 while the get was in flight.
                    Self.tab(id: racedID, worktreeID: worktreeID, revision: 11, label: "newer"),
                    Self.tab(id: untouchedID, worktreeID: worktreeID, revision: 2),
                    // Closed in the daemon; the get is authoritative about it
                    // being gone even though the mirror still holds it.
                    Self.tab(id: goneID, worktreeID: worktreeID, revision: 5),
                ],
                activeTabID: racedID)
            state.panelGetFetcher = { _ in
                PanelGetResult(
                    tabs: [
                        Self.tab(id: racedID, worktreeID: worktreeID, revision: 10, label: "older"),
                        Self.tab(id: untouchedID, worktreeID: worktreeID, revision: 4, label: "fresh"),
                    ],
                    activeTabID: untouchedID)
            }

            await state.loadPanelSurface(worktreeID: worktreeID)

            let tabs = state.panelSurfaces[worktreeID]?.tabs ?? []
            #expect(tabs.count == 2, "a tab absent from the fetch is removed, not kept")
            #expect(tabs.first { $0.id == racedID }?.label == "newer",
                    "the in-flight get is a snapshot from before the delta")
            #expect(tabs.first { $0.id == untouchedID }?.revision == 4,
                    "a tab the fetch advances is still adopted")
            #expect(tabs.allSatisfy { $0.id != goneID })
            #expect(state.panelSurfaces[worktreeID]?.activeTabID == untouchedID,
                    "selection follows the fetch, which defines the tab set")
        }
    }

    // MARK: - Loading

    @Test("loadPanelSurface populates the mirror when the flag is on and is inert when off")
    func loadRespectsTheFlag() async {
        let worktreeID = UUID()
        let tabID = UUID()
        let fetched = PanelGetResult(
            tabs: [Self.tab(id: tabID, worktreeID: worktreeID, revision: 4)], activeTabID: tabID)

        await Self.makeState(flagEnabled: true) { state, _ in
            var gets: [UUID] = []
            state.panelGetFetcher = { id in
                gets.append(id)
                return fetched
            }
            await state.loadPanelSurface(worktreeID: worktreeID)

            #expect(gets == [worktreeID])
            #expect(state.panelSurfaces[worktreeID] == fetched)
        }

        await Self.makeState(flagEnabled: false) { state, _ in
            var gets: [UUID] = []
            state.panelGetFetcher = { id in
                gets.append(id)
                return fetched
            }
            await state.loadPanelSurface(worktreeID: worktreeID)

            #expect(gets.isEmpty, "flag off must not even fetch")
            #expect(state.panelSurfaces.isEmpty)
        }
    }

    @Test("a failing panel.get leaves the previous mirror value in place")
    func loadFailureKeepsLastKnownMirror() async {
        await Self.makeState(flagEnabled: true) { state, _ in
            let worktreeID = UUID()
            let tabID = UUID()
            let known = PanelGetResult(
                tabs: [Self.tab(id: tabID, worktreeID: worktreeID, revision: 9)],
                activeTabID: tabID)
            state.panelSurfaces[worktreeID] = known
            state.panelGetFetcher = { _ in throw ApplyRejected() }

            await state.loadPanelSurface(worktreeID: worktreeID)

            #expect(state.panelSurfaces[worktreeID] == known)
        }
    }

    // MARK: - The apply chokepoint

    @Test("applyPanelOperation sends the mirror's current revision and upserts the result")
    func applySendsBaseRevisionAndUpserts() async throws {
        try await Self.makeState(flagEnabled: true) { state, _ in
            let worktreeID = UUID()
            let tabID = UUID()
            let otherTabID = UUID()
            state.panelSurfaces[worktreeID] = PanelGetResult(
                tabs: [
                    Self.tab(id: tabID, worktreeID: worktreeID, revision: 12),
                    Self.tab(id: otherTabID, worktreeID: worktreeID, revision: 3, label: "other"),
                ],
                activeTabID: tabID)

            let panelID = UUID()
            let committed = WorkspaceTabSurface(
                id: tabID, worktreeID: worktreeID, label: "after",
                primary: .terminal(terminalID: tabID),
                layout: .split(SplitNode(
                    id: UUID(), direction: .horizontal,
                    children: [.primary, .panel(PanelSlot(id: panelID, content: .web(URL(string: "https://example.com")!)))],
                    ratios: [0.5, 0.5])),
                revision: 13)
            var envelopes: [PanelOperationEnvelope] = []
            state.panelApplyTrigger = { envelope in
                envelopes.append(envelope)
                return PanelApplyResult(tab: committed, replayed: false)
            }

            await state.applyPanelOperation(
                worktreeID: worktreeID, tabID: tabID,
                operation: .open(content: .web(URL(string: "https://example.com")!),
                                 placement: .automatic))

            #expect(envelopes.count == 1)
            let envelope = try #require(envelopes.first)
            #expect(envelope.baseRevision == 12, "baseRevision is the mirror's CURRENT revision")
            #expect(envelope.worktreeID == worktreeID)
            #expect(envelope.tabID == tabID)
            #expect(envelope.origin == .appUser)
            #expect(envelope.operation == .open(
                content: .web(URL(string: "https://example.com")!), placement: .automatic))

            let tabs = state.panelSurfaces[worktreeID]?.tabs ?? []
            #expect(tabs.first { $0.id == tabID } == committed,
                    "the mirror takes the daemon's authoritative tab from the response")
            #expect(tabs.first { $0.id == otherTabID }?.label == "other",
                    "a sibling tab is untouched by an apply")
            #expect(state.panelSurfaces[worktreeID]?.activeTabID == tabID,
                    "an apply does not move the active tab")
        }
    }

    @Test("an apply response older than the mirror does not revert it")
    func staleApplyResponseIsDropped() async {
        await Self.makeState(flagEnabled: true) { state, _ in
            let worktreeID = UUID()
            let tabID = UUID()
            state.panelSurfaces[worktreeID] = PanelGetResult(
                tabs: [Self.tab(id: tabID, worktreeID: worktreeID, revision: 30)],
                activeTabID: tabID)
            state.panelApplyTrigger = { _ in
                // A delta for a later operation landed while this apply was
                // in flight, so its response is already behind the mirror.
                PanelApplyResult(
                    tab: Self.tab(id: tabID, worktreeID: worktreeID, revision: 29, label: "stale"),
                    replayed: false)
            }

            await state.applyPanelOperation(
                worktreeID: worktreeID, tabID: tabID, operation: .close(panelID: UUID()))

            #expect(state.panelSurfaces[worktreeID]?.tabs.first?.revision == 30)
            #expect(state.panelSurfaces[worktreeID]?.tabs.first?.label == nil)
        }
    }

    @Test("applyPanelOperation sends a nil baseRevision when the mirror has no such tab")
    func applyWithoutMirrorEntrySendsNilBaseRevision() async {
        await Self.makeState(flagEnabled: true) { state, _ in
            let worktreeID = UUID()
            let tabID = UUID()
            let committed = Self.tab(id: tabID, worktreeID: worktreeID, revision: 1)
            var envelopes: [PanelOperationEnvelope] = []
            state.panelApplyTrigger = { envelope in
                envelopes.append(envelope)
                return PanelApplyResult(tab: committed, replayed: false)
            }

            await state.applyPanelOperation(
                worktreeID: worktreeID, tabID: tabID, operation: .close(panelID: UUID()))

            #expect(envelopes.first?.baseRevision == nil)
            #expect(state.panelSurfaces[worktreeID]?.tabs == [committed],
                    "the response seeds the mirror even when it had no entry")
        }
    }

    @Test("a rejected apply refetches the surface so the UI snaps to daemon truth")
    func applyFailureRefetches() async {
        await Self.makeState(flagEnabled: true) { state, _ in
            let worktreeID = UUID()
            let tabID = UUID()
            // The mirror is stale: an agent already moved the tab to rev 20.
            state.panelSurfaces[worktreeID] = PanelGetResult(
                tabs: [Self.tab(id: tabID, worktreeID: worktreeID, revision: 5)],
                activeTabID: tabID)
            let truth = PanelGetResult(
                tabs: [Self.tab(id: tabID, worktreeID: worktreeID, revision: 20, label: "truth")],
                activeTabID: tabID)

            state.panelApplyTrigger = { _ in throw ApplyRejected() }
            var gets: [UUID] = []
            state.panelGetFetcher = { id in
                gets.append(id)
                return truth
            }

            await state.applyPanelOperation(
                worktreeID: worktreeID, tabID: tabID, operation: .close(panelID: UUID()))

            #expect(gets == [worktreeID], "a rejected apply must refetch exactly once")
            #expect(state.panelSurfaces[worktreeID] == truth)
        }
    }

    @Test("flag OFF: applyPanelOperation fires no RPC and mutates nothing")
    func applyIsInertWithFlagOff() async {
        await Self.makeState(flagEnabled: false) { state, _ in
            let worktreeID = UUID()
            let tabID = UUID()
            var applyCalls = 0
            state.panelApplyTrigger = { _ in
                applyCalls += 1
                return PanelApplyResult(
                    tab: Self.tab(id: tabID, worktreeID: worktreeID, revision: 1), replayed: false)
            }

            await state.applyPanelOperation(
                worktreeID: worktreeID, tabID: tabID, operation: .close(panelID: UUID()))

            #expect(applyCalls == 0)
            #expect(state.panelSurfaces.isEmpty)
        }
    }
}
