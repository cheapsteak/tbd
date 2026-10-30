import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import DaemonTestSupport
import TestSupport

/// Router-level tests for `panel.get` / `panel.apply` / `panel.syncTabs`.
/// Exercises ROUTING only — `PanelCoordinator`'s gating, reduce and
/// broadcast behavior is covered by `PanelCoordinatorTests`, and the sync's
/// behavior by `PanelSyncTabsTests`. Here we check that each method reaches
/// the coordinator, that the gate error surfaces as a string naming
/// `panel_tabs_enabled`, and that a malformed payload decodes to an error
/// response.
@Suite("Panel RPC Tests")
struct PanelRPCTests {

    private func makeRouterAndDB() throws -> (RPCRouter, TBDDatabase) {
        let db = try TBDDatabase(inMemory: true)
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
            actuationLog: makeTestActuationLog()
        )
        return (router, db)
    }

    private func makeWorktree(_ db: TBDDatabase, name: String = "w") async throws -> UUID {
        let repo = try await db.repos.create(
            path: "/tmp/prpc-\(UUID())", displayName: name, defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: name, branch: "b",
            path: "/tmp/prpc-wt-\(UUID())", tmuxServer: "srv")
        return wt.id
    }

    /// Seeds one tab through the store: a terminal primary plus one side
    /// panel — mirrors `PanelCoordinatorTests.seedTab`.
    @discardableResult
    private func seedTab(
        _ db: TBDDatabase, worktreeID: UUID, tabID: UUID = UUID(), panelID: PanelID = UUID(),
        panelContent: PanelContent = .file(FileReference(path: "/a.txt"))
    ) async throws -> WorkspaceTabSurface {
        let surface = WorkspaceTabSurface(
            id: tabID, worktreeID: worktreeID, label: "tab",
            primary: .terminal(terminalID: UUID()),
            side: SideRegion(
                panels: [ViewerPanel(id: panelID, content: panelContent)],
                activePanelID: panelID, recency: [panelID], collapsed: false, width: 0.5),
            revision: 0)
        try await db.panelSurface.commit(surface: surface, position: 0, receipt: nil, now: Date())
        return surface
    }

    private func openEnvelope(
        worktreeID: UUID, tabID: UUID, origin: PanelOperationOrigin
    ) -> PanelOperationEnvelope {
        PanelOperationEnvelope(
            operationID: UUID(), worktreeID: worktreeID, tabID: tabID, baseRevision: nil,
            origin: origin,
            operation: .open(content: .file(FileReference(path: "/b.txt")), newPanel: false))
    }

    // MARK: - panel.get (ungated)

    @Test("panel.get on an empty store returns an empty result, no error, flag unset")
    func getOnEmptyStoreReturnsEmptyResult() async throws {
        let (router, _) = try makeRouterAndDB()
        let request = try RPCRequest(
            method: RPCMethod.panelGet, params: PanelGetParams(worktreeID: UUID()))
        let response = await router.handle(request)
        #expect(response.success)
        let result = try response.decodeResult(PanelGetResult.self)
        #expect(result.tabs.isEmpty)
    }

    @Test("panel.get reflects a committed tab with the flag unset")
    func getReflectsCommittedTab() async throws {
        let (router, db) = try makeRouterAndDB()
        let wtID = try await makeWorktree(db)
        let tab = try await seedTab(db, worktreeID: wtID)

        let request = try RPCRequest(
            method: RPCMethod.panelGet, params: PanelGetParams(worktreeID: wtID))
        let response = await router.handle(request)
        #expect(response.success)
        let result = try response.decodeResult(PanelGetResult.self)
        #expect(result.tabs.map(\.id) == [tab.id])
    }

    // MARK: - panel.apply gating surfaces the flag by name

    @Test("panel.apply names panel_tabs_enabled when the flag is unset or off",
          arguments: [PanelOperationOrigin.appUser, .agentCLI])
    func applyDisabledNamesFlag(origin: PanelOperationOrigin) async throws {
        let (router, db) = try makeRouterAndDB()
        let wtID = try await makeWorktree(db)
        let tab = try await seedTab(db, worktreeID: wtID)
        let params = PanelApplyParams(envelope: openEnvelope(worktreeID: wtID, tabID: tab.id, origin: origin))

        // Never chosen.
        let unsetResponse = await router.handle(try RPCRequest(method: RPCMethod.panelApply, params: params))
        #expect(!unsetResponse.success)
        #expect(unsetResponse.error?.contains("panel_tabs_enabled") == true)

        // Explicitly off.
        try await db.config.setPanelTabsEnabled(false)
        let offResponse = await router.handle(try RPCRequest(method: RPCMethod.panelApply, params: params))
        #expect(!offResponse.success)
        #expect(offResponse.error?.contains("panel_tabs_enabled") == true)
    }

    // MARK: - panel.apply happy path + panel.get reflects it

    @Test("panel.apply commits with the flag on, for the app and an agent alike, and panel.get reflects it",
          arguments: [PanelOperationOrigin.appUser, .agentCLI])
    func applyHappyPathThenGetReflectsResult(origin: PanelOperationOrigin) async throws {
        let (router, db) = try makeRouterAndDB()
        try await db.config.setPanelTabsEnabled(true)
        let wtID = try await makeWorktree(db)
        let tab = try await seedTab(db, worktreeID: wtID)

        let applyRequest = try RPCRequest(
            method: RPCMethod.panelApply,
            params: PanelApplyParams(envelope: openEnvelope(worktreeID: wtID, tabID: tab.id, origin: origin)))
        let applyResponse = await router.handle(applyRequest)
        #expect(applyResponse.success)
        let applyResult = try applyResponse.decodeResult(PanelApplyResult.self)
        #expect(applyResult.replayed == false)
        #expect(applyResult.tab.revision == 1)

        let getRequest = try RPCRequest(method: RPCMethod.panelGet, params: PanelGetParams(worktreeID: wtID))
        let getResponse = await router.handle(getRequest)
        #expect(getResponse.success)
        let getResult = try getResponse.decodeResult(PanelGetResult.self)
        #expect(getResult.tabs.first?.revision == 1)
    }

    // MARK: - malformed params

    @Test("panel.apply with malformed params JSON decodes to an error response")
    func applyMalformedParamsDecodesToError() async throws {
        let (router, _) = try makeRouterAndDB()
        let request = RPCRequest(method: RPCMethod.panelApply, params: #"{"not":"an envelope"}"#)
        let response = await router.handle(request)
        #expect(!response.success)
    }

    @Test("panel.syncTabs with malformed params JSON decodes to an error response")
    func syncTabsMalformedParamsDecodesToError() async throws {
        let (router, _) = try makeRouterAndDB()
        let request = RPCRequest(method: RPCMethod.panelSyncTabs, params: #"{"not":"a tab list"}"#)
        let response = await router.handle(request)
        #expect(!response.success)
        #expect(response.error?.contains("Unknown method") == false)
    }

    // MARK: - panel.syncTabs dispatch (behavior lives in PanelSyncTabsTests)

    @Test("panel.syncTabs dispatches to its handler and names the flag when it is unset")
    func syncTabsDispatchesToHandler() async throws {
        let (router, _) = try makeRouterAndDB()
        let params = PanelSyncTabsParams(worktreeID: UUID(), tabs: [], paneHistories: [:])
        let request = try RPCRequest(method: RPCMethod.panelSyncTabs, params: params)
        let response = await router.handle(request)
        #expect(!response.success)
        #expect(response.error?.contains("Unknown method") == false)
        #expect(response.error?.contains("panel_tabs_enabled") == true)
    }
}
