import Foundation
import Testing
import TBDShared
@testable import TBDApp

// Tier 1: deterministic, in-process state only (see `PanelTabsTestSupport`).

/// The app's copy of the daemon-owned panel surfaces (panel tabs spec, "The
/// app's copy of the surface" and "Round trip and conflicts"): its gate on
/// `panel_tabs_enabled`, the revision guard, removals, the full-get merge, the
/// resubscribe refetch, and the `panel.apply` chokepoint.
@Suite("Panel surface copy")
@MainActor
struct PanelSurfaceCopyTests {
    private typealias Fixture = PanelTabsFixture

    // MARK: - The gate

    @Test("flag off: a delta and a load both leave the copy as it was")
    func flagOffLeavesCopyUntouched() async {
        await Fixture.withState(panelTabs: false) { state in
            let worktreeID = UUID()
            let heldID = UUID()
            // The copy can only be non-empty with the flag off if something
            // seeded it; seeding makes "untouched" observable, not just "empty".
            let held = Fixture.surface(tabID: heldID, worktreeID: worktreeID, revision: 3)
            let seeded: PanelSurfaceCopy = [worktreeID: [heldID: held]]
            state.panelSurfaces = seeded

            state.handleDelta(.panelSurfaceChanged(Fixture.delta(
                worktreeID: worktreeID,
                tabs: [Fixture.surface(tabID: UUID(), worktreeID: worktreeID, revision: 1)],
                removed: [heldID])))
            #expect(state.panelSurfaces == seeded, "a delta with the flag off must change nothing")

            // The unstubbed `panel.get` records an issue if the load fetches.
            await state.loadPanelSurfaces(worktreeID: worktreeID)
            #expect(state.panelSurfaces == seeded, "a load with the flag off must not even fetch")
        }
    }

    // MARK: - Deltas

    @Test("a delta upserts its tabs and leaves the others alone")
    func deltaUpserts() async {
        await Fixture.withState(panelTabs: true) { state in
            let worktreeID = UUID()
            let keptID = UUID()
            let updatedID = UUID()

            state.handleDelta(.panelSurfaceChanged(Fixture.delta(
                worktreeID: worktreeID,
                tabs: [
                    Fixture.surface(tabID: keptID, worktreeID: worktreeID, revision: 1, label: "kept"),
                    Fixture.surface(tabID: updatedID, worktreeID: worktreeID, revision: 1, label: "old"),
                ])))
            state.handleDelta(.panelSurfaceChanged(Fixture.delta(
                worktreeID: worktreeID,
                tabs: [Fixture.surface(tabID: updatedID, worktreeID: worktreeID, revision: 2, label: "new")])))

            #expect(state.panelSurfaces[worktreeID]?.count == 2)
            #expect(state.panelSurface(worktreeID: worktreeID, tabID: keptID)?.label == "kept")
            let updated = state.panelSurface(worktreeID: worktreeID, tabID: updatedID)
            #expect(updated?.revision == 2)
            #expect(updated?.label == "new")
        }
    }

    @Test("an older revision is refused, by a delta and by a full get")
    func olderRevisionRefused() async {
        await Fixture.withState(panelTabs: true) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let current = Fixture.surface(tabID: tabID, worktreeID: worktreeID, revision: 9, label: "current")
            state.panelSurfaces = [worktreeID: [tabID: current]]

            state.handleDelta(.panelSurfaceChanged(Fixture.delta(
                worktreeID: worktreeID,
                tabs: [Fixture.surface(tabID: tabID, worktreeID: worktreeID, revision: 8, label: "stale")])))
            #expect(state.panelSurface(worktreeID: worktreeID, tabID: tabID) == current)

            // A get taken before the delta that brought revision 9, resolving
            // after it.
            let gets = Fixture.collectGets(state) { _ in
                PanelGetResult(
                    tabs: [Fixture.surface(tabID: tabID, worktreeID: worktreeID, revision: 8, label: "stale")],
                    activeTabID: nil)
            }
            await state.loadPanelSurfaces(worktreeID: worktreeID)
            #expect(gets.worktreeIDs == [worktreeID])
            #expect(state.panelSurface(worktreeID: worktreeID, tabID: tabID) == current)
        }
    }

    @Test("a removal applies whatever revision the copy holds")
    func removalAppliedWhateverRevision() async {
        await Fixture.withState(panelTabs: true) { state in
            let worktreeID = UUID()
            let removedID = UUID()
            let keptID = UUID()
            state.panelSurfaces = [worktreeID: [
                removedID: Fixture.surface(tabID: removedID, worktreeID: worktreeID, revision: 40),
                keptID: Fixture.surface(tabID: keptID, worktreeID: worktreeID, revision: 1),
            ]]

            state.handleDelta(.panelSurfaceChanged(
                Fixture.delta(worktreeID: worktreeID, removed: [removedID])))

            #expect(state.panelSurface(worktreeID: worktreeID, tabID: removedID) == nil,
                    "the revision guard applies to content, never to removal")
            #expect(state.panelSurface(worktreeID: worktreeID, tabID: keptID) != nil)

            state.handleDelta(.panelSurfaceChanged(
                Fixture.delta(worktreeID: worktreeID, removed: [keptID])))
            #expect(state.panelSurfaces[worktreeID] == nil,
                    "a worktree with no surfaces left drops out of the copy")
        }
    }

    @Test("a full get drops tabs it does not list")
    func fullGetDropsAbsentTabs() async {
        await Fixture.withState(panelTabs: true) { state in
            let worktreeID = UUID()
            let listedID = UUID()
            let goneID = UUID()
            state.panelSurfaces = [worktreeID: [
                listedID: Fixture.surface(tabID: listedID, worktreeID: worktreeID, revision: 2),
                // Held at a higher revision than anything the get carries:
                // absence still wins.
                goneID: Fixture.surface(tabID: goneID, worktreeID: worktreeID, revision: 50),
            ]]
            let fetched = Fixture.surface(tabID: listedID, worktreeID: worktreeID, revision: 3, label: "fresh")
            _ = Fixture.collectGets(state) { _ in
                PanelGetResult(tabs: [fetched], activeTabID: listedID)
            }

            await state.loadPanelSurfaces(worktreeID: worktreeID)

            let expected: [WorkspaceTabID: WorkspaceTabSurface] = [listedID: fetched]
            #expect(state.panelSurfaces[worktreeID] == expected)
        }
    }

    // MARK: - Loading the shown tab

    @Test("a shown tab asks for a load only while the flag is on and the copy holds no surface for it")
    func loadKeyAsksForALoadOnlyForAShownTabWithoutASurface() async {
        await Fixture.withState(panelTabs: true) { state in
            let worktreeID = UUID()
            let surfaced = Fixture.terminalTab(label: "surfaced")
            let alsoSurfaced = Fixture.terminalTab(label: "also surfaced")
            let bare = Fixture.terminalTab(label: "no surface")
            state.panelSurfaces = [worktreeID: [
                surfaced.id: Fixture.surface(tabID: surfaced.id, worktreeID: worktreeID, revision: 1),
                alsoSurfaced.id: Fixture.surface(tabID: alsoSurfaced.id, worktreeID: worktreeID, revision: 2),
            ]]

            let onSurfaced = state.panelSurfaceLoadKey(worktreeID: worktreeID, activeTabID: surfaced.id)
            let onAlsoSurfaced = state.panelSurfaceLoadKey(worktreeID: worktreeID, activeTabID: alsoSurfaced.id)
            let onBare = state.panelSurfaceLoadKey(worktreeID: worktreeID, activeTabID: bare.id)
            let onNoTab = state.panelSurfaceLoadKey(worktreeID: worktreeID, activeTabID: nil)

            #expect(onBare.loads, "a failed load or a missed import is retried when the tab is shown")
            #expect(!onSurfaced.loads, "deltas keep a tab with a surface current")
            #expect(!onNoTab.loads)
            #expect(onSurfaced == onAlsoSurfaced, "switching between tabs with surfaces reruns nothing")
            #expect(onSurfaced != onBare, "switching to a tab without one reruns the load task")

            state.daemonCapabilities = Fixture.capabilities(panelTabs: false)
            let flagOff = state.panelSurfaceLoadKey(worktreeID: worktreeID, activeTabID: bare.id)
            #expect(!flagOff.loads)
            #expect(flagOff != onBare, "the flag turning on reruns the load task")
        }
    }

    @Test("a shown tab without a surface loads after the pending sync; one with a surface loads nothing")
    func shownTabWithoutSurfaceLoadsAfterThePendingSync() async throws {
        try await Fixture.withState(panelTabs: true) { state in
            let tab = Fixture.terminalTab(label: "agent")
            let worktreeID = await Fixture.readyWorktree(state, tabs: [tab], syncs: Fixture.collectSyncs(state))
            let log = PanelEventLog()
            _ = Fixture.collectSyncs(state, into: log)
            let imported = Fixture.surface(tabID: tab.id, worktreeID: worktreeID, revision: 3)
            let gets = Fixture.collectGets(state, into: log) { _ in
                PanelGetResult(tabs: [imported], activeTabID: nil)
            }
            // A change whose sync has not gone out yet.
            state.tabs[worktreeID]?[0].label = "renamed"
            let bareKey = state.panelSurfaceLoadKey(worktreeID: worktreeID, activeTabID: tab.id)

            await state.loadPanelSurfacesForShownTab(bareKey)

            let expectedEvents: [String] = ["sync \(worktreeID)", "get \(worktreeID)"]
            #expect(log.events == expectedEvents,
                    "the get follows the pending sync, so the snapshot holds what that sync imports")
            #expect(state.panelSurface(worktreeID: worktreeID, tabID: tab.id) == imported)

            let surfacedKey = state.panelSurfaceLoadKey(worktreeID: worktreeID, activeTabID: tab.id)
            await state.loadPanelSurfacesForShownTab(surfacedKey)
            await Fixture.drainMainActor()
            #expect(gets.worktreeIDs == [worktreeID], "a tab with a surface asks for no load")
        }
    }

    @Test("a full get keeps a tab a delta adopted while it was in flight")
    func getKeepsTabAdoptedFromDeltaInFlight() async {
        await Fixture.withState(panelTabs: true) { state in
            let worktreeID = UUID()
            let keptID = UUID()
            let droppedID = UUID()
            let importedID = UUID()
            state.panelSurfaces = [worktreeID: [
                keptID: Fixture.surface(tabID: keptID, worktreeID: worktreeID, revision: 1),
                droppedID: Fixture.surface(tabID: droppedID, worktreeID: worktreeID, revision: 1),
            ]]
            let imported = Fixture.surface(tabID: importedID, worktreeID: worktreeID, revision: 0)
            let keptFresh = Fixture.surface(tabID: keptID, worktreeID: worktreeID, revision: 2)
            let importDelta = StateDelta.panelSurfaceChanged(
                Fixture.delta(worktreeID: worktreeID, tabs: [imported]))
            state.panelGetFetcher = { @MainActor [weak state] _ in
                // A sync's import lands while the get is in flight; the get's
                // snapshot was taken before it.
                state?.handleDelta(importDelta)
                return PanelGetResult(tabs: [keptFresh], activeTabID: nil)
            }

            await state.loadPanelSurfaces(worktreeID: worktreeID)

            #expect(state.panelSurface(worktreeID: worktreeID, tabID: importedID) == imported,
                    "a tab adopted from a delta during the get is not the get's to drop")
            #expect(state.panelSurface(worktreeID: worktreeID, tabID: keptID) == keptFresh)
            #expect(state.panelSurface(worktreeID: worktreeID, tabID: droppedID) == nil,
                    "a tab held when the get was issued, and omitted by it, is still dropped")
            #expect(state.panelLoadsInFlight == 0)
            #expect(state.panelTabsTouchedInFlight.isEmpty, "the touch log empties with the last load")
        }
    }

    @Test("a full get does not put back a tab a delta removed while it was in flight")
    func getDoesNotRestoreTabRemovedInFlight() async {
        await Fixture.withState(panelTabs: true) { state in
            let worktreeID = UUID()
            let removedID = UUID()
            let otherID = UUID()
            let removed = Fixture.surface(tabID: removedID, worktreeID: worktreeID, revision: 3)
            state.panelSurfaces = [worktreeID: [
                removedID: removed,
                otherID: Fixture.surface(tabID: otherID, worktreeID: worktreeID, revision: 1),
            ]]
            let otherFresh = Fixture.surface(tabID: otherID, worktreeID: worktreeID, revision: 2)
            let removalDelta = StateDelta.panelSurfaceChanged(
                Fixture.delta(worktreeID: worktreeID, removed: [removedID]))
            state.panelGetFetcher = { @MainActor [weak state] _ in
                // The tab is closed while the get is in flight; the get's
                // snapshot was taken before the close.
                state?.handleDelta(removalDelta)
                return PanelGetResult(tabs: [removed, otherFresh], activeTabID: nil)
            }

            await state.loadPanelSurfaces(worktreeID: worktreeID)

            #expect(state.panelSurface(worktreeID: worktreeID, tabID: removedID) == nil,
                    "a stale listing must not put back a tab removed during the get")
            #expect(state.panelSurface(worktreeID: worktreeID, tabID: otherID) == otherFresh)
        }
    }

    @Test("a full get that lists a tab held under another worktree moves it there; an older listing does not")
    func mergeEvictsTabFromOtherWorktree() async {
        await Fixture.withState(panelTabs: true) { state in
            let scratchID = UUID()
            let mainID = UUID()
            let movedID = UUID()
            let keptID = UUID()
            let kept = Fixture.surface(tabID: keptID, worktreeID: scratchID, revision: 2)
            let beforeMove = Fixture.surface(tabID: movedID, worktreeID: scratchID, revision: 4)
            state.panelSurfaces = [scratchID: [movedID: beforeMove, keptID: kept]]
            // Promoting the scratch worktree re-parented the tab, and the
            // delta saying so reached no subscription.
            let moved = Fixture.surface(tabID: movedID, worktreeID: mainID, revision: 9)
            _ = Fixture.collectGets(state) { worktreeID in
                worktreeID == mainID
                    ? PanelGetResult(tabs: [moved], activeTabID: nil)
                    // A snapshot of the scratch worktree from before the move.
                    : PanelGetResult(tabs: [beforeMove, kept], activeTabID: nil)
            }

            await state.loadPanelSurfaces(worktreeID: mainID)

            #expect(state.panelSurface(worktreeID: mainID, tabID: movedID) == moved)
            #expect(state.panelSurface(worktreeID: scratchID, tabID: movedID) == nil,
                    "a tab ID lives under one worktree, as `adopt` keeps it")
            #expect(state.panelSurface(worktreeID: scratchID, tabID: keptID) == kept)

            await state.loadPanelSurfaces(worktreeID: scratchID)

            #expect(state.panelSurface(worktreeID: mainID, tabID: movedID) == moved,
                    "revisions are daemon-wide, so the guard refuses an older copy held elsewhere")
            #expect(state.panelSurface(worktreeID: scratchID, tabID: movedID) == nil)
            #expect(state.panelSurface(worktreeID: scratchID, tabID: keptID) == kept)
        }
    }

    @Test("a delta's activeTabID does not move the selected workspace tab")
    func deltaActiveTabIDIgnored() async {
        await Fixture.withState(panelTabs: true) { state in
            let worktreeID = UUID()
            let first = Fixture.terminalTab(label: "first")
            let second = Fixture.terminalTab(label: "second")
            state.tabs[worktreeID] = [first, second]
            state.activeTabIndices[worktreeID] = 0
            let surface = Fixture.surface(tabID: second.id, worktreeID: worktreeID, revision: 1)

            state.handleDelta(.panelSurfaceChanged(Fixture.delta(
                worktreeID: worktreeID, tabs: [surface], activeTabID: second.id)))

            #expect(state.activeTabIndices[worktreeID] == 0,
                    "workspace-tab selection is the app's; the delta only reports it back")
            #expect(state.panelSurface(worktreeID: worktreeID, tabID: second.id) == surface,
                    "the delta's tabs are still adopted")
        }
    }

    // MARK: - A worktree going away

    @Test("an archived worktree drops out of the copy, though it keeps its tabs entry")
    func archivedWorktreeDropsItsCopyEntry() async {
        await Fixture.withState(panelTabs: true) { state in
            let archivedID = UUID()
            let keptID = UUID()
            let archivedTab = Fixture.terminalTab(label: "archived")
            let keptTab = Fixture.terminalTab(label: "kept")
            let kept = Fixture.surface(tabID: keptTab.id, worktreeID: keptID, revision: 1)
            state.tabs = [archivedID: [archivedTab], keptID: [keptTab]]
            state.panelSurfaces = [
                archivedID: [archivedTab.id: Fixture.surface(
                    tabID: archivedTab.id, worktreeID: archivedID, revision: 4)],
                keptID: [keptTab.id: kept],
            ]

            state.removeArchivedWorktreeFromState(id: archivedID)

            #expect(state.tabs[archivedID] != nil, "precondition: archive leaves the tabs entry")
            #expect(state.panelSurfaces[archivedID] == nil, "the daemon deleted its surfaces")
            #expect(state.panelSurface(worktreeID: keptID, tabID: keptTab.id) == kept)
            await Fixture.drainMainActor()
        }
    }

    @Test("archiving a worktree forgets its pending tab sync and its readiness")
    func forgetClearsDirtyAndReadiness() async {
        await Fixture.withState(panelTabs: true) { state in
            let syncs = Fixture.collectSyncs(state)
            let archivedID = await Fixture.readyWorktree(
                state, tabs: [Fixture.terminalTab(label: "archived")], syncs: syncs)
            let keptID = await Fixture.readyWorktree(
                state, tabs: [Fixture.terminalTab(label: "kept")], syncs: syncs)
            // A change whose sync has not gone out when the archive lands.
            state.tabs[archivedID]?[0].label = "renamed"
            #expect(state.panelSyncDirty.contains(archivedID), "precondition: a sync is pending")

            state.removeArchivedWorktreeFromState(id: archivedID)
            await Fixture.drainMainActor()

            #expect(syncs.sent.isEmpty, "an archived worktree's tab list is not synced")
            #expect(!state.panelSyncDirty.contains(archivedID))
            #expect(!state.panelSyncReadyWorktrees.contains(archivedID),
                    "a revive marks it ready again from fresh fetches")
            #expect(state.panelSyncReadyWorktrees.contains(keptID), "other worktrees stay ready")
        }
    }

    // MARK: - Resubscribe

    @Test("a resubscribe keeps rendering the copy and refetches only the worktrees it holds")
    func resubscribeRefetchesHeldWorktrees() async throws {
        try await Fixture.withState(panelTabs: true) { state in
            let syncs = Fixture.collectSyncs(state)
            let tab = Fixture.terminalTab(label: "agent")
            let worktreeID = await Fixture.readyWorktree(state, tabs: [tab], syncs: syncs)
            // A worktree with tabs whose surfaces the copy never loaded.
            let unloadedID = await Fixture.readyWorktree(
                state, tabs: [Fixture.terminalTab(label: "other")], syncs: syncs)
            let held = Fixture.surface(tabID: tab.id, worktreeID: worktreeID, revision: 7)
            state.panelSurfaces = [worktreeID: [tab.id: held]]
            // A change the daemon made, and broadcast, while no subscription
            // was up.
            let missed = Fixture.surface(tabID: tab.id, worktreeID: worktreeID, revision: 9, label: "missed")
            let gate = PanelCallGate()
            let gets = PanelGetCollector()
            state.panelGetFetcher = { @MainActor requested in
                gets.record(requested)
                await gate.wait()
                return PanelGetResult(tabs: [missed], activeTabID: nil)
            }
            // `startSubscription` re-seeds program status too; answered here so
            // the test sends no RPC of its own for it.
            state.programStatusListFetcher = { @MainActor in [] }
            let subscription = Fixture.stubSubscription(state)
            defer { subscription.end() }

            state.startSubscription()
            await Fixture.drainMainActor()
            subscription.register()
            await Fixture.drainMainActor()

            try #require(gate.isHolding, "precondition: the refetch is in flight")
            #expect(gets.worktreeIDs == [worktreeID], "only a worktree the copy holds is refetched")
            #expect(state.workspaceRenderPath(worktreeID: worktreeID, tabID: tab.id) == .daemon(held),
                    "the tab keeps rendering from the copy rather than dropping to legacy")
            #expect(syncs.sent.isEmpty,
                    "readiness was cleared, so nothing is synced before both tab sources reload")
            #expect(state.panelSyncDirty.isSuperset(of: [worktreeID, unloadedID]))

            gate.release()
            await Fixture.drainMainActor()

            #expect(state.panelSurface(worktreeID: worktreeID, tabID: tab.id) == missed,
                    "the refetch merges the change the subscription missed")

            state.markPanelSyncReady(worktreeIDs: [worktreeID])
            await Fixture.drainMainActor()

            let sent = try Fixture.single(syncs.sent)
            #expect(sent.worktreeID == worktreeID)
            #expect(sent.tabs.map(\.tabID) == [tab.id])
        }
    }

    /// The daemon registers a subscriber before it acknowledges it. A refetch
    /// answered before registration could miss a change that no delta then
    /// reports, so the refetch waits for the acknowledgement.
    @Test("a resubscribe refetches the copy's worktrees only once the daemon registers the subscription")
    func resubscribeRefetchesAfterSubscribing() async throws {
        try await Fixture.withState(panelTabs: true) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            state.panelSurfaces = [worktreeID: [
                tabID: Fixture.surface(tabID: tabID, worktreeID: worktreeID, revision: 4),
            ]]
            let missed = Fixture.surface(tabID: tabID, worktreeID: worktreeID, revision: 6, label: "missed")
            let gets = Fixture.collectGets(state) { _ in
                PanelGetResult(tabs: [missed], activeTabID: nil)
            }
            state.programStatusListFetcher = { @MainActor in [] }
            let subscription = Fixture.stubSubscription(state)
            defer { subscription.end() }

            state.startSubscription()
            await Fixture.drainMainActor()

            try #require(subscription.isOpen, "precondition: the subscribe call is in flight")
            #expect(gets.worktreeIDs.isEmpty, "nothing is refetched before the daemon registers the subscription")

            subscription.register()
            await Fixture.drainMainActor()

            #expect(gets.worktreeIDs == [worktreeID], "the acknowledgement refetches the worktree the copy holds")
            #expect(state.panelSurface(worktreeID: worktreeID, tabID: tabID) == missed)
        }
    }

    /// A load issued before the subscription registered, and answered by the
    /// daemon before it did, can miss a change; it fetches once more.
    @Test("a get in flight when the daemon registers the subscription fetches again; one issued after does not")
    func getInFlightAcrossRegistrationFetchesAgain() async {
        await Fixture.withState(panelTabs: true) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let stale = Fixture.surface(tabID: tabID, worktreeID: worktreeID, revision: 2, label: "stale")
            let fresh = Fixture.surface(tabID: tabID, worktreeID: worktreeID, revision: 5, label: "fresh")
            let gets = PanelGetCollector()
            state.panelGetFetcher = { @MainActor [weak state] requested in
                gets.record(requested)
                guard gets.worktreeIDs.count == 1 else {
                    return PanelGetResult(tabs: [fresh], activeTabID: nil)
                }
                // The ack lands while the first get is in flight. The copy
                // holds nothing yet, so the acknowledgement refetches nothing
                // of its own.
                state?.panelSubscriptionRegistered()
                return PanelGetResult(tabs: [stale], activeTabID: nil)
            }

            await state.loadPanelSurfaces(worktreeID: worktreeID)
            await Fixture.drainMainActor()

            #expect(gets.worktreeIDs == [worktreeID, worktreeID])
            #expect(state.panelSurface(worktreeID: worktreeID, tabID: tabID) == fresh)

            await state.loadPanelSurfaces(worktreeID: worktreeID)
            await Fixture.drainMainActor()

            #expect(gets.worktreeIDs.count == 3, "a get issued after the acknowledgement fetches once")
        }
    }

    /// At connect the flag turns on and the subscription starts before any
    /// load lands. The copy is still empty then, so the subscription refetches
    /// nothing, and the flag turning on loads each worktree once.
    @Test("launch loads each worktree's surfaces once")
    func launchLoadsEachWorktreeOnce() async throws {
        try await Fixture.withState(panelTabs: nil) { state in
            let syncs = Fixture.collectSyncs(state)
            let alpha = Fixture.terminalTab(label: "alpha")
            let beta = Fixture.terminalTab(label: "beta")
            let alphaID = await Fixture.readyWorktree(state, tabs: [alpha], syncs: syncs)
            let betaID = await Fixture.readyWorktree(state, tabs: [beta], syncs: syncs)
            let gets = Fixture.collectGets(state) { worktreeID in
                let tab = worktreeID == alphaID ? alpha : beta
                return PanelGetResult(
                    tabs: [Fixture.surface(tabID: tab.id, worktreeID: worktreeID, revision: 1)],
                    activeTabID: nil)
            }
            state.programStatusListFetcher = { @MainActor in [] }

            // `connectAndLoadInitialState`: capabilities arrive with the flag
            // on, then the subscription starts.
            state.daemonCapabilities = Fixture.capabilities(panelTabs: true)
            state.panelTabsCapabilityChanged(wasEnabled: false)
            state.startSubscription()
            state.stopSubscription()
            await Fixture.drainMainActor()

            #expect(gets.worktreeIDs.count == 2, "observed \(gets.worktreeIDs)")
            #expect(Set(gets.worktreeIDs) == [alphaID, betaID])
            #expect(state.panelSurface(worktreeID: alphaID, tabID: alpha.id) != nil)
            #expect(state.panelSurface(worktreeID: betaID, tabID: beta.id) != nil)
        }
    }

    // MARK: - The apply chokepoint

    @Test("apply sends the held revision as its base and adopts the reply")
    func applyAdoptsReplyTab() async throws {
        try await Fixture.withState(panelTabs: true) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            state.panelSurfaces = [worktreeID: [
                tabID: Fixture.surface(tabID: tabID, worktreeID: worktreeID, revision: 3),
            ]]
            let reply = Fixture.surface(tabID: tabID, worktreeID: worktreeID, revision: 4, label: "after")
            let envelopes = Fixture.collectEnvelopes(state, replying: reply)
            let operation = PanelOperation.setCollapsed(true)

            let returned = await state.applyPanelOperation(worktreeID: worktreeID, tabID: tabID, operation)

            let envelope = try Fixture.single(envelopes.envelopes)
            #expect(envelope.worktreeID == worktreeID)
            #expect(envelope.tabID == tabID)
            #expect(envelope.baseRevision == 3, "baseRevision is the copy's current revision")
            #expect(envelope.origin == .appUser)
            #expect(envelope.operation == operation)
            #expect(returned == reply)
            #expect(state.panelSurface(worktreeID: worktreeID, tabID: tabID) == reply)
        }
    }

    @Test("a failed apply shows a toast and refetches the worktree")
    func applyFailureToastsAndRefetches() async {
        await Fixture.withState(panelTabs: true) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            state.panelSurfaces = [worktreeID: [
                tabID: Fixture.surface(tabID: tabID, worktreeID: worktreeID, revision: 5),
            ]]
            state.panelApplyTrigger = { @MainActor _ in
                throw PanelTabsFixture.Rejected(message: "No panel with that ID")
            }
            let truth = Fixture.surface(tabID: tabID, worktreeID: worktreeID, revision: 20, label: "truth")
            let gets = Fixture.collectGets(state) { _ in
                PanelGetResult(tabs: [truth], activeTabID: nil)
            }

            let returned = await state.applyPanelOperation(
                worktreeID: worktreeID, tabID: tabID, .close(panelID: UUID()))

            #expect(returned == nil)
            #expect(state.activeToast?.message == "No panel with that ID")
            #expect(state.activeToast?.style == .error)
            #expect(gets.worktreeIDs == [worktreeID], "a failed apply refetches exactly once")
            #expect(state.panelSurface(worktreeID: worktreeID, tabID: tabID) == truth)
            state.dismissToast()
        }
    }

    // MARK: - The flag turning off

    @Test("the flag turning off clears the copy and stops every apply and sync")
    func flagOffClearsCopyAndStopsSync() async {
        await Fixture.withState(panelTabs: true) { state in
            let syncs = Fixture.collectSyncs(state)
            let tab = Fixture.terminalTab(label: "agent")
            let worktreeID = await Fixture.readyWorktree(state, tabs: [tab], syncs: syncs)
            state.panelSurfaces = [worktreeID: [
                tab.id: Fixture.surface(tabID: tab.id, worktreeID: worktreeID, revision: 2),
            ]]
            let off = Fixture.capabilities(panelTabs: false)
            state.daemonCapabilitiesFetcher = { @MainActor in off }

            await state.refreshDaemonCapabilities()

            #expect(state.panelTabsActive == false)
            #expect(state.panelSurfaces.isEmpty, "a daemon-rendered tab must fall back to legacy at once")
            #expect(state.panelSyncDirty.isEmpty)

            state.tabs[worktreeID]?.append(Fixture.terminalTab(label: "new"))
            await Fixture.drainMainActor()
            #expect(syncs.sent.isEmpty, "no panel.syncTabs goes out with the flag off")

            // The unstubbed `panel.apply` records an issue if the apply sends.
            let returned = await state.applyPanelOperation(
                worktreeID: worktreeID, tabID: tab.id, .setCollapsed(true))
            #expect(returned == nil)
            #expect(state.panelSurfaces.isEmpty)
        }
    }
}
