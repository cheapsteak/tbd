import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import DaemonTestSupport
import TestSupport

/// `panel.syncTabs` over RPC (panel tabs spec, "Tab sync"): the gate, legacy
/// conversion of tabs without a surface, skip reasons, deletion of unlisted
/// tabs, re-parenting, and exactly one broadcast per sync that changed
/// something; and the removal an archive broadcasts for the surfaces it
/// deletes. The conversion itself is covered by `LegacyTabConverterTests`
/// and the transaction by `PanelSurfaceStoreTests`.
@Suite("Panel syncTabs tests")
struct PanelSyncTabsTests {

    /// Router whose panel-surface broadcasts are captured in `deltas`.
    private func makeRouterAndDB() throws -> (router: RPCRouter, db: TBDDatabase, deltas: SyncBroadcastDeltas) {
        let db = try TBDDatabase(inMemory: true)
        let deltas = SyncBroadcastDeltas()
        let subs = StateSubscriptionManager()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            subscriptions: subs,
            actuationLog: makeTestActuationLog()
        )
        return (router, db, deltas)
    }

    private func makeWorktree(_ db: TBDDatabase, name: String = "w") async throws -> UUID {
        let repo = try await db.repos.create(
            path: "/tmp/pst-\(UUID())", displayName: name, defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: name, branch: "b",
            path: "/tmp/pst-wt-\(UUID())", tmuxServer: "srv")
        return wt.id
    }

    private func panelSurfaceDeltas(_ deltas: SyncBroadcastDeltas) -> [PanelSurfaceDelta] {
        deltas.snapshot().compactMap {
            if case .panelSurfaceChanged(let delta) = $0 { return delta }
            return nil
        }
    }

    private func sync(
        _ router: RPCRouter, worktreeID: UUID, _ tabs: [LegacyTabPayload],
        paneHistories: [UUID: MRUHistory<PaneContent>] = [:]
    ) async throws -> RPCResponse {
        let params = PanelSyncTabsParams(worktreeID: worktreeID, tabs: tabs, paneHistories: paneHistories)
        return await router.handle(try RPCRequest(method: RPCMethod.panelSyncTabs, params: params))
    }

    /// A plain terminal tab with no layout.
    private func terminalTab(_ tabID: UUID = UUID(), label: String? = nil) -> LegacyTabPayload {
        LegacyTabPayload(tabID: tabID, label: label, content: .terminal(terminalID: UUID()), layout: nil)
    }

    /// A terminal tab split with one code viewer beside it.
    private func viewerTab(
        _ tabID: UUID = UUID(), label: String? = nil, terminalID: UUID = UUID(),
        viewerID: UUID = UUID(), path: String = "/one"
    ) -> LegacyTabPayload {
        let layout = LayoutNode.split(
            id: UUID(), direction: .horizontal,
            children: [.pane(.terminal(terminalID: terminalID)), .pane(.codeViewer(id: viewerID, path: path))],
            ratios: [0.6, 0.4])
        return LegacyTabPayload(
            tabID: tabID, label: label, content: .terminal(terminalID: terminalID), layout: layout)
    }

    private static func file(_ path: String) -> PanelContent {
        .file(FileReference(path: path))
    }

    // MARK: - Gate

    @Test("sync refuses with the flag unset or off, naming panel_tabs_enabled, and writes nothing")
    func syncRefusesWhenFlagOff() async throws {
        let (router, db, deltas) = try makeRouterAndDB()
        let wtID = try await makeWorktree(db)
        let tabs = [terminalTab()]

        let unset = try await sync(router, worktreeID: wtID, tabs)
        #expect(!unset.success)
        #expect(unset.error?.contains("panel_tabs_enabled") == true)

        try await db.config.setPanelTabsEnabled(false)
        let off = try await sync(router, worktreeID: wtID, tabs)
        #expect(!off.success)
        #expect(off.error?.contains("panel_tabs_enabled") == true)

        #expect(try await db.panelSurface.surfaces(worktreeID: wtID).isEmpty)
        #expect(panelSurfaceDeltas(deltas).isEmpty)
    }

    // MARK: - Import

    @Test("sync imports every listed tab without a surface, in order, with its pane history")
    func syncImportsTabsWithoutSurfaces() async throws {
        let (router, db, deltas) = try makeRouterAndDB()
        try await db.config.setPanelTabsEnabled(true)
        let wtID = try await makeWorktree(db)
        let tabAID = UUID()
        let tabBID = UUID()
        let viewerID = UUID()
        let legacyHistory: MRUHistory<PaneContent> = {
            var built = MRUHistory<PaneContent>.seeded(with: .codeViewer(id: viewerID, path: "/zero"))
            built.recordReplacement(
                outgoing: .codeViewer(id: viewerID, path: "/zero"),
                incoming: .codeViewer(id: viewerID, path: "/one"))
            return built
        }()

        let response = try await sync(
            router, worktreeID: wtID,
            [viewerTab(tabAID, label: "A", viewerID: viewerID), terminalTab(tabBID, label: "B")],
            paneHistories: [viewerID: legacyHistory])

        #expect(response.success)
        let result = try response.decodeResult(PanelSyncTabsResult.self)
        #expect(result.importedTabIDs == [tabAID, tabBID])
        #expect(result.reparentedTabIDs.isEmpty)
        #expect(result.removedTabIDs.isEmpty)
        #expect(result.skipped.isEmpty)

        let surfaces = try await db.panelSurface.surfaces(worktreeID: wtID)
        #expect(surfaces.map(\.id) == [tabAID, tabBID])
        #expect(surfaces.map(\.label) == ["A", "B"])
        let importedA = try #require(surfaces.first)
        let importedB = try #require(surfaces.last)
        #expect(importedA.revision > 0 && importedA.revision < importedB.revision,
                "each import takes the daemon-wide counter's next value")
        let panel = try #require(importedA.side.panels.first)
        #expect(importedA.side.panels.count == 1)
        #expect(panel.content == Self.file("/one"))
        // The legacy history survives, mapped to panel content.
        #expect(panel.history.entries.contains(Self.file("/zero")))
        #expect(surfaces.last?.side.panels.isEmpty == true)

        let broadcasts = panelSurfaceDeltas(deltas)
        #expect(broadcasts.count == 1)
        let delta = try #require(broadcasts.first)
        #expect(delta.worktreeID == wtID)
        #expect(delta.tabs.map(\.id) == [tabAID, tabBID])
        #expect(delta.removedTabIDs.isEmpty)
        #expect(delta.activeTabID == nil)
        #expect(delta.originOperationID == nil)
    }

    @Test("a tab with a terminal outside its primary is skipped with a reason and gets no surface")
    func syncSkipsATerminalSplitTab() async throws {
        let (router, db, deltas) = try makeRouterAndDB()
        try await db.config.setPanelTabsEnabled(true)
        let wtID = try await makeWorktree(db)
        let splitTabID = UUID()
        let plainTabID = UUID()
        let mainTerminal = UUID()
        let layout = LayoutNode.split(
            id: UUID(), direction: .horizontal,
            children: [.pane(.terminal(terminalID: mainTerminal)), .pane(.terminal(terminalID: UUID()))],
            ratios: [0.5, 0.5])
        let splitTab = LegacyTabPayload(
            tabID: splitTabID, label: nil, content: .terminal(terminalID: mainTerminal), layout: layout)

        let response = try await sync(router, worktreeID: wtID, [splitTab, terminalTab(plainTabID)])

        #expect(response.success)
        let result = try response.decodeResult(PanelSyncTabsResult.self)
        #expect(result.importedTabIDs == [plainTabID])
        #expect(result.skipped.count == 1)
        #expect(result.skipped.first?.contains(splitTabID.uuidString) == true)
        #expect(try await db.panelSurface.surface(tabID: splitTabID) == nil)
        #expect(try await db.panelSurface.surfaces(worktreeID: wtID).map(\.id) == [plainTabID])
        #expect(panelSurfaceDeltas(deltas).count == 1)
    }

    // MARK: - Delete

    @Test("a tab missing from the list is deleted and named in removedTabIDs and the delta")
    func syncDeletesAnUnlistedTab() async throws {
        let (router, db, deltas) = try makeRouterAndDB()
        try await db.config.setPanelTabsEnabled(true)
        let wtID = try await makeWorktree(db)
        let tabA = terminalTab(label: "A")
        let tabB = viewerTab(label: "B")
        _ = try await sync(router, worktreeID: wtID, [tabA, tabB])
        #expect(panelSurfaceDeltas(deltas).count == 1)

        let response = try await sync(router, worktreeID: wtID, [tabA])

        #expect(response.success)
        let result = try response.decodeResult(PanelSyncTabsResult.self)
        #expect(result.removedTabIDs == [tabB.tabID])
        #expect(result.importedTabIDs.isEmpty)
        #expect(try await db.panelSurface.surfaces(worktreeID: wtID).map(\.id) == [tabA.tabID])
        #expect(try await db.panelSurface.surface(tabID: tabB.tabID) == nil)

        let broadcasts = panelSurfaceDeltas(deltas)
        #expect(broadcasts.count == 2)
        let delta = try #require(broadcasts.last)
        #expect(delta.removedTabIDs == [tabB.tabID])
        // Tab A kept its position, label and primary, so it did not change.
        #expect(delta.tabs.isEmpty)
    }

    @Test("an empty tab list deletes every surface of the worktree")
    func syncWithNoTabsDeletesEverySurface() async throws {
        let (router, db, deltas) = try makeRouterAndDB()
        try await db.config.setPanelTabsEnabled(true)
        let wtID = try await makeWorktree(db)
        let tabA = terminalTab()
        let tabB = terminalTab()
        _ = try await sync(router, worktreeID: wtID, [tabA, tabB])

        let response = try await sync(router, worktreeID: wtID, [])

        #expect(response.success)
        let result = try response.decodeResult(PanelSyncTabsResult.self)
        #expect(result.removedTabIDs == [tabA.tabID, tabB.tabID])
        #expect(try await db.panelSurface.surfaces(worktreeID: wtID).isEmpty)
        #expect(panelSurfaceDeltas(deltas).last?.removedTabIDs == [tabA.tabID, tabB.tabID])
    }

    // MARK: - Broadcast once, and only on change

    @Test("each sync broadcasts at most once, and an unchanged re-sync broadcasts nothing")
    func syncBroadcastsOnceAndNotWhenUnchanged() async throws {
        let (router, db, deltas) = try makeRouterAndDB()
        try await db.config.setPanelTabsEnabled(true)
        let wtID = try await makeWorktree(db)
        let tabs = [viewerTab(label: "A"), terminalTab(label: "B"), terminalTab(label: "C")]

        _ = try await sync(router, worktreeID: wtID, tabs)
        #expect(panelSurfaceDeltas(deltas).count == 1)

        let again = try await sync(router, worktreeID: wtID, tabs)
        #expect(again.success)
        let result = try again.decodeResult(PanelSyncTabsResult.self)
        #expect(result.importedTabIDs.isEmpty)
        #expect(result.reparentedTabIDs.isEmpty)
        #expect(result.removedTabIDs.isEmpty)
        #expect(panelSurfaceDeltas(deltas).count == 1)
    }

    // MARK: - Update and never overwrite

    @Test("a reorder and relabel update the surfaces' own fields and keep their panels")
    func syncUpdatesOrderAndLabelButNeverPanels() async throws {
        let (router, db, deltas) = try makeRouterAndDB()
        try await db.config.setPanelTabsEnabled(true)
        let wtID = try await makeWorktree(db)
        let tabAID = UUID()
        let terminalA = UUID()
        let tabB = terminalTab()
        _ = try await sync(
            router, worktreeID: wtID, [viewerTab(tabAID, label: "A", terminalID: terminalA), tabB])

        // An agent opens a second panel in tab A.
        let open = PanelOperationEnvelope(
            operationID: UUID(), worktreeID: wtID, tabID: tabAID, baseRevision: nil, origin: .agentCLI,
            operation: .open(content: Self.file("/agent.txt"), newPanel: true))
        let applyResponse = await router.handle(
            try RPCRequest(method: RPCMethod.panelApply, params: PanelApplyParams(envelope: open)))
        let applied = try applyResponse.decodeResult(PanelApplyResult.self).tab
        #expect(applied.side.panels.count == 2)

        // The app reorders and relabels; its legacy layout for A holds one
        // viewer on another file, which must not replace the agent's panels.
        let response = try await sync(
            router, worktreeID: wtID,
            [tabB, viewerTab(tabAID, label: "A renamed", terminalID: terminalA, path: "/legacy")])

        #expect(response.success)
        let result = try response.decodeResult(PanelSyncTabsResult.self)
        #expect(result.importedTabIDs.isEmpty)
        let surfaces = try await db.panelSurface.surfaces(worktreeID: wtID)
        #expect(surfaces.map(\.id) == [tabB.tabID, tabAID])
        let updatedA = try #require(surfaces.last)
        #expect(updatedA.label == "A renamed")
        #expect(updatedA.primary == .terminal(terminalID: terminalA))
        #expect(updatedA.side == applied.side)
        #expect(updatedA.revision > applied.revision)

        // One delta for the sync, carrying both repositioned tabs.
        let delta = try #require(panelSurfaceDeltas(deltas).last)
        #expect(Set(delta.tabs.map(\.id)) == Set([tabAID, tabB.tabID]))
        #expect(delta.removedTabIDs.isEmpty)
        #expect(delta.originOperationID == nil)
    }

    // MARK: - Re-parent

    @Test("a listed tab whose surface sits under another worktree moves with its panels")
    func syncReparentsASurface() async throws {
        let (router, db, deltas) = try makeRouterAndDB()
        try await db.config.setPanelTabsEnabled(true)
        let scratchID = try await makeWorktree(db, name: "scratch")
        let mainID = try await makeWorktree(db, name: "main")
        let tab = viewerTab(label: "moved")
        _ = try await sync(router, worktreeID: scratchID, [tab])
        let before = try #require(try await db.panelSurface.surface(tabID: tab.tabID))

        let response = try await sync(router, worktreeID: mainID, [tab])

        #expect(response.success)
        let result = try response.decodeResult(PanelSyncTabsResult.self)
        #expect(result.reparentedTabIDs == [tab.tabID])
        #expect(result.importedTabIDs.isEmpty)
        let after = try #require(try await db.panelSurface.surface(tabID: tab.tabID))
        #expect(after.worktreeID == mainID)
        #expect(after.side == before.side)
        #expect(try await db.panelSurface.surfaces(worktreeID: scratchID).isEmpty)

        let delta = try #require(panelSurfaceDeltas(deltas).last)
        #expect(delta.worktreeID == mainID)
        #expect(delta.tabs.map(\.id) == [tab.tabID])
    }

    // MARK: - Archive

    @Test("archiving a worktree broadcasts the removal of every panel surface it deleted")
    func archiveBroadcastsRemovalOfItsSurfaces() async throws {
        let deltas = SyncBroadcastDeltas()
        let subs = StateSubscriptionManager()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let harness = try await ArchiveHarness.make(subscriptions: subs)
        defer { harness.cleanUp() }
        let worktreeID = harness.worktreeID
        let tabIDs = [UUID(), UUID()]
        let entries = tabIDs.enumerated().map { position, tabID in
            SyncTabEntry(
                tabID: tabID, position: position, label: nil, primary: nil,
                importCandidate: WorkspaceTabSurface(
                    id: tabID, worktreeID: worktreeID, primary: .terminal(terminalID: UUID())))
        }
        let imported = try await harness.db.panelSurface.syncTabs(
            worktreeID: worktreeID, entries: entries, now: Date())
        #expect(imported.imported == tabIDs, "precondition: the worktree has surfaces")

        try await harness.lifecycle.archiveWorktree(worktreeID: worktreeID)

        let removals = panelSurfaceDeltas(deltas).filter { $0.worktreeID == worktreeID }
        try #require(removals.count == 1, "one removal per archive, observed \(removals)")
        let removal = removals[0]
        #expect(removal.removedTabIDs == tabIDs)
        #expect(removal.tabs.isEmpty)
        #expect(removal.originOperationID == nil)
        #expect(try await harness.db.panelSurface.surfaces(worktreeID: worktreeID).isEmpty)
    }
}

/// Thread-safe collector for broadcast `StateDelta`s.
private final class SyncBroadcastDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [StateDelta] = []

    func append(_ delta: StateDelta) {
        lock.lock(); defer { lock.unlock() }
        deltas.append(delta)
    }

    func snapshot() -> [StateDelta] {
        lock.lock(); defer { lock.unlock() }
        return deltas
    }
}
