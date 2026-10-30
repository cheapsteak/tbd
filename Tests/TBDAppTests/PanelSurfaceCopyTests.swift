import Foundation
import Testing
import TBDShared
@testable import TBDApp

// Tier 1: deterministic, in-process state only (see `PanelTabsTestSupport`).

/// The app's copy of the daemon-owned panel surfaces (panel tabs spec, "The
/// app's copy of the surface" and "Round trip and conflicts"): its gate on
/// `panel_tabs_enabled`, the revision guard, removals, the full-get merge, the
/// reset on resubscribe, and the `panel.apply` chokepoint.
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

    @Test("a get reply from before a resubscribe reset is discarded")
    func resultFromBeforeResetIsDiscarded() async {
        await Fixture.withState(panelTabs: true) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let oldDaemon = Fixture.surface(tabID: tabID, worktreeID: worktreeID, revision: 7)
            // `tabs` stays empty, so the reset itself starts no reload.
            state.panelGetFetcher = { @MainActor [weak state] _ in
                state?.resetPanelSurfacesForResubscribe()
                return PanelGetResult(tabs: [oldDaemon], activeTabID: nil)
            }

            await state.loadPanelSurfaces(worktreeID: worktreeID)

            #expect(state.panelSurfaces.isEmpty,
                    "an old daemon's revision 7 would make the guard refuse the new daemon's lower ones")

            // The new daemon's lower revision is then adopted, not refused.
            let newDaemon = Fixture.surface(tabID: tabID, worktreeID: worktreeID, revision: 0)
            _ = Fixture.collectGets(state) { _ in
                PanelGetResult(tabs: [newDaemon], activeTabID: nil)
            }
            await state.loadPanelSurfaces(worktreeID: worktreeID)
            #expect(state.panelSurface(worktreeID: worktreeID, tabID: tabID) == newDaemon)
        }
    }

    @Test("an apply reply from before a resubscribe reset is not adopted")
    func applyReplyFromBeforeResetIsDiscarded() async {
        await Fixture.withState(panelTabs: true) { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let oldDaemon = Fixture.surface(tabID: tabID, worktreeID: worktreeID, revision: 7)
            state.panelApplyTrigger = { @MainActor [weak state] _ in
                state?.resetPanelSurfacesForResubscribe()
                return PanelApplyResult(tab: oldDaemon, replayed: false)
            }

            let returned = await state.applyPanelOperation(
                worktreeID: worktreeID, tabID: tabID, .setCollapsed(true))

            #expect(returned == nil)
            #expect(state.panelSurfaces.isEmpty)
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

    @Test("a worktree that leaves tabs drops out of the copy; others stay")
    func worktreeLeavingTabsDropsItsCopyEntry() async {
        await Fixture.withState(panelTabs: true) { state in
            let goneID = UUID()
            let keptID = UUID()
            let goneTab = Fixture.terminalTab(label: "gone")
            let keptTab = Fixture.terminalTab(label: "kept")
            let kept = Fixture.surface(tabID: keptTab.id, worktreeID: keptID, revision: 1)
            state.tabs = [goneID: [goneTab], keptID: [keptTab]]
            state.panelSurfaces = [
                goneID: [goneTab.id: Fixture.surface(tabID: goneTab.id, worktreeID: goneID, revision: 4)],
                keptID: [keptTab.id: kept],
            ]

            state.tabs.removeValue(forKey: goneID)

            #expect(state.panelSurfaces[goneID] == nil)
            #expect(state.panelSurface(worktreeID: keptID, tabID: keptTab.id) == kept)
            await Fixture.drainMainActor()
        }
    }

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
            #expect(state.panelSurfaces[archivedID] == nil,
                    "the daemon deleted its surfaces; held revisions would refuse a revive's re-imports")
            #expect(state.panelSurface(worktreeID: keptID, tabID: keptTab.id) == kept)
            await Fixture.drainMainActor()
        }
    }

    // MARK: - Resubscribe

    @Test("a resubscribe clears the copy and refetches, adopting a lower revision")
    func resubscribeClearsAndRefetches() async throws {
        try await Fixture.withState(panelTabs: true) { state in
            let syncs = Fixture.collectSyncs(state)
            let tab = Fixture.terminalTab(label: "agent")
            let worktreeID = await Fixture.readyWorktree(state, tabs: [tab], syncs: syncs)
            state.panelSurfaces = [worktreeID: [
                tab.id: Fixture.surface(tabID: tab.id, worktreeID: worktreeID, revision: 7),
            ]]
            // A restarted daemon: its migration cleared the rows, so the
            // re-imported surface counts from zero again.
            let restarted = Fixture.surface(tabID: tab.id, worktreeID: worktreeID, revision: 0)
            let gets = Fixture.collectGets(state) { _ in
                PanelGetResult(tabs: [restarted], activeTabID: nil)
            }
            // `startSubscription` re-seeds program status too; answered here so
            // the test sends no RPC of its own for it.
            state.programStatusListFetcher = { @MainActor in [] }

            state.startSubscription()
            // Only the reset is under test: the subscription it started has no
            // daemon to reach, and is ended at once.
            state.stopSubscription()
            await Fixture.drainMainActor()

            #expect(gets.worktreeIDs == [worktreeID])
            #expect(state.panelSurface(worktreeID: worktreeID, tabID: tab.id) == restarted,
                    "the guard would refuse revision 0 against 7 had the copy not been cleared")
            #expect(syncs.sent.isEmpty,
                    "readiness was cleared, so nothing is synced before both tab sources reload")
            #expect(state.panelSyncDirty.contains(worktreeID))

            state.markPanelSyncReady(worktreeIDs: [worktreeID])
            await Fixture.drainMainActor()

            let sent = try Fixture.single(syncs.sent)
            #expect(sent.worktreeID == worktreeID)
            #expect(sent.tabs.map(\.tabID) == [tab.id])
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
