import Foundation
import Testing
import TBDShared
@testable import TBDApp

// Tier 1: deterministic, in-process state only (see `PanelTabsTestSupport`).

/// The workspace-tab sync (panel tabs spec, "Tab sync" and "The app's copy of
/// the surface"): one observer on `tabs` marks a worktree dirty when its tab
/// IDs, order, labels or primaries change, and one `panel.syncTabs` per dirty
/// worktree goes out on the next main-actor turn — but only once that
/// worktree's tab list is complete, because a sync deletes the surface of
/// every tab it does not list.
@Suite("Panel tab sync")
@MainActor
struct PanelTabSyncTests {
    private typealias Fixture = PanelTabsFixture

    // MARK: - What sends a sync

    @Test("creating a tab sends one sync listing every tab")
    func tabCreateSendsOneSync() async throws {
        try await Fixture.withState(panelTabs: true) { state in
            let syncs = Fixture.collectSyncs(state)
            let first = Fixture.terminalTab(label: "agent")
            let worktreeID = await Fixture.readyWorktree(state, tabs: [first], syncs: syncs)
            let created = Fixture.terminalTab(label: "shell")

            state.tabs[worktreeID]?.append(created)
            await Fixture.drainMainActor()

            let sent = try Fixture.single(syncs.sent)
            #expect(sent.worktreeID == worktreeID)
            #expect(sent.tabs.map(\.tabID) == [first.id, created.id])
        }
    }

    @Test("a relabelled tab and a re-pointed primary each send a sync")
    func labelOrPrimaryChangeSendsSync() async throws {
        try await Fixture.withState(panelTabs: true) { state in
            let syncs = Fixture.collectSyncs(state)
            let tab = TBDShared.Tab(
                id: UUID(), content: .codeViewer(id: UUID(), path: "/repo/a.swift"), label: "a.swift")
            let worktreeID = await Fixture.readyWorktree(state, tabs: [tab], syncs: syncs)

            state.tabs[worktreeID]?[0].label = "renamed"
            await Fixture.drainMainActor()
            let relabelled = try Fixture.single(syncs.sent)
            #expect(relabelled.tabs.first?.label == "renamed")

            syncs.reset()
            // The file viewer points a file tab at a new file in place.
            let repointed = PaneContent.codeViewer(id: UUID(), path: "/repo/b.swift")
            state.tabs[worktreeID]?[0].content = repointed
            await Fixture.drainMainActor()
            let moved = try Fixture.single(syncs.sent)
            #expect(moved.tabs.first?.content == repointed)
        }
    }

    @Test("reordering tabs sends a sync in the new order")
    func reorderSendsSync() async throws {
        try await Fixture.withState(panelTabs: true) { state in
            let syncs = Fixture.collectSyncs(state)
            let first = Fixture.terminalTab(label: "first")
            let second = Fixture.terminalTab(label: "second")
            let worktreeID = await Fixture.readyWorktree(state, tabs: [first, second], syncs: syncs)

            state.tabs[worktreeID] = [second, first]
            await Fixture.drainMainActor()

            let sent = try Fixture.single(syncs.sent)
            #expect(sent.tabs.map(\.tabID) == [second.id, first.id])
        }
    }

    @Test("several changes in one turn send one sync per worktree, with the final tabs")
    func twoChangesInOneTurnSendOneSyncPerWorktree() async throws {
        try await Fixture.withState(panelTabs: true) { state in
            let syncs = Fixture.collectSyncs(state)
            let alpha = Fixture.terminalTab(label: "alpha")
            let beta = Fixture.terminalTab(label: "beta")
            let alphaWorktree = await Fixture.readyWorktree(state, tabs: [alpha], syncs: syncs)
            let betaWorktree = await Fixture.readyWorktree(state, tabs: [beta], syncs: syncs)
            let added = Fixture.terminalTab(label: "added")

            // One synchronous turn: two edits to one worktree, one to another.
            state.tabs[alphaWorktree]?.append(added)
            state.tabs[alphaWorktree]?[0].label = "alpha renamed"
            state.tabs[betaWorktree]?[0].label = "beta renamed"
            await Fixture.drainMainActor()

            #expect(syncs.sent.count == 2, "observed \(syncs.sent.map(\.worktreeID))")
            #expect(Set(syncs.sent.map(\.worktreeID)) == [alphaWorktree, betaWorktree])
            let alphaSync = try #require(syncs.sent.first(where: { $0.worktreeID == alphaWorktree }))
            #expect(alphaSync.tabs.map(\.tabID) == [alpha.id, added.id])
            #expect(alphaSync.tabs.first?.label == "alpha renamed")
            let betaSync = try #require(syncs.sent.first(where: { $0.worktreeID == betaWorktree }))
            #expect(betaSync.tabs.first?.label == "beta renamed")
        }
    }

    @Test("a change made while a sync is in flight goes out after it, not beside it")
    func changeDuringSyncIsSentAfterIt() async throws {
        try await Fixture.withState(panelTabs: true) { state in
            let syncs = PanelSyncCollector()
            let first = Fixture.terminalTab(label: "first")
            let late = Fixture.terminalTab(label: "late")
            let worktreeID = UUID()
            state.panelSyncTrigger = { @MainActor [weak state] params in
                syncs.record(params)
                // The first sync is "in flight" while this runs: a tab created
                // now must wait for it.
                if syncs.sent.count == 1 {
                    state?.tabs[worktreeID]?.append(late)
                }
                return Fixture.emptySyncResult
            }

            state.tabs[worktreeID] = [first]
            state.markPanelSyncReady(worktreeIDs: [worktreeID])
            await Fixture.drainMainActor()

            let sentLists: [[UUID]] = syncs.sent.map { $0.tabs.map(\.tabID) }
            let expectedLists: [[UUID]] = [[first.id], [first.id, late.id]]
            #expect(sentLists == expectedLists)
        }
    }

    // MARK: - What does not

    @Test("state that is not the tab list sends no sync")
    func unrelatedStateChangeSendsNoSync() async {
        await Fixture.withState(panelTabs: true) { state in
            let syncs = Fixture.collectSyncs(state)
            let tab = Fixture.terminalTab(label: "agent")
            let worktreeID = await Fixture.readyWorktree(state, tabs: [tab], syncs: syncs)

            // `reconcileTabs` re-assigns an identical list on every terminal
            // activity flip.
            state.tabs[worktreeID] = [tab]
            state.activeTabIndices[worktreeID] = 0
            state.worktreeTabOrders[worktreeID] = [tab.id]
            state.panelSurfaces = [worktreeID: [
                tab.id: Fixture.surface(tabID: tab.id, worktreeID: worktreeID, revision: 1),
            ]]
            // No sync skipped the tab, so its layout is not offered again.
            state.layouts[tab.id] = .pane(tab.content)
            await Fixture.drainMainActor()

            #expect(syncs.sent.isEmpty, "observed \(syncs.sent.map(\.worktreeID))")
        }
    }

    @Test("flag off: tab changes send no sync")
    func flagOffSendsNoSync() async {
        await Fixture.withState(panelTabs: false) { state in
            let syncs = Fixture.collectSyncs(state)
            let tab = Fixture.terminalTab(label: "agent")
            let worktreeID = await Fixture.readyWorktree(state, tabs: [tab], syncs: syncs)

            state.tabs[worktreeID]?.append(Fixture.terminalTab(label: "shell"))
            state.tabs[worktreeID]?[0].label = "renamed"
            await Fixture.drainMainActor()

            #expect(syncs.sent.isEmpty)
            #expect(state.panelSyncDirty.isEmpty, "the observer does no work with the flag off")
        }
    }

    // MARK: - Legacy layouts

    /// A tab the daemon skipped: its legacy layout holds a second terminal
    /// beside the primary.
    private static func skippedTab() -> (tab: TBDShared.Tab, layout: LayoutNode) {
        let tab = Fixture.terminalTab(label: "agent")
        let layout = LayoutNode.split(
            id: UUID(), direction: .horizontal,
            children: [.pane(tab.content), .pane(.terminal(terminalID: UUID()))],
            ratios: [0.5, 0.5])
        return (tab, layout)
    }

    @Test("a layout change of a tab the sync skipped sends a sync carrying the new layout")
    func layoutChangeOfSurfacelessTabSendsSync() async throws {
        try await Fixture.withState(panelTabs: true) { state in
            let (tab, split) = Self.skippedTab()
            // The daemon skips the tab while its layout holds the second
            // terminal, and imports it once that terminal is gone.
            let syncs = PanelSyncCollector()
            state.panelSyncTrigger = { @MainActor params in
                syncs.record(params)
                let stillSplit = params.tabs.contains { $0.tabID == tab.id && $0.layout == split }
                return Fixture.syncResult(skipping: stillSplit ? [tab.id] : [])
            }
            // Not yet in `tabs`, so this marks nothing.
            state.layouts[tab.id] = split
            let worktreeID = await Fixture.readyWorktree(state, tabs: [tab], syncs: syncs)
            #expect(state.panelSyncSkippedTabIDs == [tab.id], "precondition: the first sync skipped it")

            // The user closes the extra terminal: `layouts` changes, `tabs`
            // does not.
            let closed = LayoutNode.pane(tab.content)
            state.layouts[tab.id] = closed
            await Fixture.drainMainActor()

            let sent = try Fixture.single(syncs.sent)
            #expect(sent.worktreeID == worktreeID)
            #expect(sent.tabs.map(\.tabID) == [tab.id])
            #expect(sent.tabs.first?.layout == closed)
            #expect(state.panelSyncSkippedTabIDs.isEmpty, "the sync that imported it replaced the verdict")
        }
    }

    @Test("a layout change of a tab no sync skipped sends no sync, though the copy holds no surface for it")
    func layoutChangeOfUnloadedTabSendsNoSync() async {
        await Fixture.withState(panelTabs: true) { state in
            let syncs = Fixture.collectSyncs(state)
            let tab = Fixture.terminalTab(label: "agent")
            let worktreeID = await Fixture.readyWorktree(state, tabs: [tab], syncs: syncs)
            #expect(state.panelSurfaces[worktreeID] == nil, "precondition: the copy has not loaded it")

            // Ordinary legacy layout writes: a viewer opened beside the
            // terminal, then closed.
            state.layouts[tab.id] = .split(
                id: UUID(), direction: .horizontal,
                children: [.pane(tab.content), .pane(.codeViewer(id: UUID(), path: "/repo/a.swift"))],
                ratios: [0.5, 0.5])
            state.layouts[tab.id] = .pane(tab.content)
            await Fixture.drainMainActor()

            #expect(syncs.sent.isEmpty, "observed \(syncs.sent.map(\.worktreeID))")
            #expect(!state.panelSyncDirty.contains(worktreeID))
        }
    }

    @Test("a layout change of a tab with a surface sends no sync")
    func layoutChangeOfSurfacedTabSendsNoSync() async {
        await Fixture.withState(panelTabs: true) { state in
            let syncs = Fixture.collectSyncs(state)
            let (tab, split) = Self.skippedTab()
            let worktreeID = await Fixture.readyWorktree(state, tabs: [tab], syncs: syncs)
            state.panelSurfaces = [worktreeID: [
                tab.id: Fixture.surface(tabID: tab.id, worktreeID: worktreeID, revision: 1),
            ]]

            state.layouts[tab.id] = split
            state.layouts[tab.id] = .pane(tab.content)
            state.layouts.removeValue(forKey: tab.id)
            await Fixture.drainMainActor()

            #expect(syncs.sent.isEmpty, "its legacy layout is not read: the daemon owns the tab")
            #expect(!state.panelSyncDirty.contains(worktreeID))
        }
    }

    // MARK: - Readiness

    @Test("a worktree whose tab sources have not both reconciled sends no sync")
    func notReadyWorktreeSendsNoSync() async {
        await Fixture.withState(panelTabs: true) { state in
            let syncs = Fixture.collectSyncs(state)
            let worktreeID = UUID()

            // Terminal-backed tabs landed; the notes fetch has not, so this
            // list lacks the note tabs and a sync of it would delete their
            // panels.
            state.tabs[worktreeID] = [Fixture.terminalTab(label: "agent")]
            state.tabs[worktreeID]?.append(Fixture.terminalTab(label: "shell"))
            await Fixture.drainMainActor()

            #expect(syncs.sent.isEmpty)
            #expect(state.panelSyncDirty.contains(worktreeID), "it stays dirty until it is ready")
        }
    }

    @Test("becoming ready flushes the worktree that was waiting dirty, once")
    func becomingReadyFlushesTheDirtyWorktree() async throws {
        try await Fixture.withState(panelTabs: true) { state in
            let syncs = Fixture.collectSyncs(state)
            let worktreeID = UUID()
            let agent = Fixture.terminalTab(label: "agent")
            let noteID = UUID()
            let note = TBDShared.Tab(id: noteID, content: .note(noteID: noteID), label: nil)
            state.tabs[worktreeID] = [agent]
            state.tabs[worktreeID]?.append(note)
            await Fixture.drainMainActor()
            #expect(syncs.sent.isEmpty)

            state.markPanelSyncReady(worktreeIDs: [worktreeID])
            await Fixture.drainMainActor()

            let sent = try Fixture.single(syncs.sent)
            #expect(sent.tabs.map(\.tabID) == [agent.id, note.id])
            #expect(state.panelSyncDirty.isEmpty)

            // Already ready: being marked again sends nothing.
            state.markPanelSyncReady(worktreeIDs: [worktreeID])
            await Fixture.drainMainActor()
            #expect(syncs.sent.count == 1)
        }
    }

    // MARK: - The flag turning on

    @Test("the flag turning on syncs every ready worktree, then loads its surfaces")
    func capabilityOffToOnSyncsAndLoads() async throws {
        try await Fixture.withState(panelTabs: false) { state in
            let log = PanelEventLog()
            let syncs = Fixture.collectSyncs(state, into: log)
            let tab = Fixture.terminalTab(label: "agent")
            let worktreeID = await Fixture.readyWorktree(state, tabs: [tab], syncs: syncs)
            let imported = Fixture.surface(tabID: tab.id, worktreeID: worktreeID, revision: 0)
            let gets = Fixture.collectGets(state, into: log) { _ in
                PanelGetResult(tabs: [imported], activeTabID: nil)
            }
            let on = Fixture.capabilities(panelTabs: true)
            state.daemonCapabilitiesFetcher = { @MainActor in on }

            await state.refreshDaemonCapabilities()
            await Fixture.drainMainActor()

            let sent = try Fixture.single(syncs.sent)
            #expect(sent.worktreeID == worktreeID)
            #expect(gets.worktreeIDs == [worktreeID])
            let expectedEvents: [String] = ["sync \(worktreeID)", "get \(worktreeID)"]
            #expect(log.events == expectedEvents,
                    "the load follows the sync, so a fetch cannot drop the tabs the sync imports")
            #expect(state.panelSurface(worktreeID: worktreeID, tabID: tab.id) == imported)
        }
    }

    @Test("the flag turning on while a sync is in flight loads only after that sync and its own")
    func offToOnWaitsForInFlightFlushBeforeLoading() async throws {
        try await Fixture.withState(panelTabs: true) { state in
            let log = PanelEventLog()
            let gate = PanelCallGate()
            let tab = Fixture.terminalTab(label: "agent")
            let worktreeID = UUID()
            state.panelSyncTrigger = { @MainActor params in
                log.record("sync \(params.worktreeID)")
                await gate.wait()
                return Fixture.emptySyncResult
            }
            let imported = Fixture.surface(tabID: tab.id, worktreeID: worktreeID, revision: 0)
            let gets = Fixture.collectGets(state, into: log) { _ in
                PanelGetResult(tabs: [imported], activeTabID: nil)
            }
            let off = Fixture.capabilities(panelTabs: false)
            let on = Fixture.capabilities(panelTabs: true)

            // A sync goes out and stays in flight.
            state.tabs[worktreeID] = [tab]
            state.markPanelSyncReady(worktreeIDs: [worktreeID])
            await Fixture.drainMainActor()
            try #require(gate.isHolding, "precondition: the first sync is in flight")

            // The flag goes off and comes back on while it is.
            state.daemonCapabilitiesFetcher = { @MainActor in off }
            await state.refreshDaemonCapabilities()
            state.daemonCapabilitiesFetcher = { @MainActor in on }
            await state.refreshDaemonCapabilities()
            await Fixture.drainMainActor()
            #expect(gets.worktreeIDs.isEmpty,
                    "a load issued now could land before the in-flight sync's imports and drop them")

            gate.release()
            await Fixture.drainMainActor()

            let expectedEvents: [String] = ["sync \(worktreeID)", "sync \(worktreeID)", "get \(worktreeID)"]
            #expect(log.events == expectedEvents,
                    "the load waits for the in-flight sync, and for the sync the flag turning on asked for")
            #expect(state.panelSurface(worktreeID: worktreeID, tabID: tab.id) == imported)
            #expect(state.panelSyncFlushTask == nil)
        }
    }
}
