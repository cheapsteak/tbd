import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Router-level tests for `panel.get` / `panel.apply` / `panel.importLegacy`
/// (Task 10, spec C §10). Exercises ROUTING only — `PanelCoordinator`'s
/// internal gating/reduce/broadcast behavior is already covered exhaustively
/// by `PanelCoordinatorTests`/`PanelCoordinatorPlacementTests`. Here we check:
/// the RPC method reaches the coordinator, the two gate errors surface as the
/// stable named-flag strings, a malformed payload decodes to an error
/// response, and `daemon.capabilities` reports the new flag.
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
            startTime: Date()
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

    /// Seeds one tab directly via the store: a primary terminal plus a side
    /// viewer panel — mirrors `PanelCoordinatorTests.seedTab`.
    @discardableResult
    private func seedTab(
        _ db: TBDDatabase, worktreeID: UUID, tabID: UUID = UUID(), panelID: PanelID = UUID(),
        panelContent: PanelContent = .file(FileReference(path: "/a.txt"))
    ) async throws -> WorkspaceTabSurface {
        let layout = PanelLayoutNode.split(SplitNode(
            id: UUID(), direction: .horizontal,
            children: [.primary, .panel(PanelSlot(id: panelID, content: panelContent))],
            ratios: [0.5, 0.5]))
        let surface = WorkspaceTabSurface(
            id: tabID, worktreeID: worktreeID, label: "tab",
            primary: .terminal(terminalID: UUID()), layout: layout, revision: 0)
        let history = PanelHistory.seeded(with: panelContent)
        let state = PanelSurfaceState(surface: surface, histories: [panelID: history])
        try await db.panelSurface.commit(state: state, position: 0, receipt: nil, now: Date())
        return surface
    }

    // MARK: - panel.get (ungated)

    @Test("panel.get on an empty store returns an empty result, no error, both flags off")
    func getOnEmptyStoreReturnsEmptyResult() async throws {
        let (router, _) = try makeRouterAndDB()
        let request = try RPCRequest(
            method: RPCMethod.panelGet, params: PanelGetParams(worktreeID: UUID()))
        let response = await router.handle(request)
        #expect(response.success)
        let result = try response.decodeResult(PanelGetResult.self)
        #expect(result.tabs.isEmpty)
    }

    @Test("panel.get reflects a committed tab")
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

    // MARK: - panel.apply gating surfaces as named-flag errors

    @Test("panel.apply surfaces the surface-disabled gate by name")
    func applySurfaceDisabledNamesFlag() async throws {
        let (router, db) = try makeRouterAndDB()
        let wtID = try await makeWorktree(db)
        let tab = try await seedTab(db, worktreeID: wtID)
        // Both flags off (default).

        let envelope = PanelOperationEnvelope(
            operationID: UUID(), worktreeID: wtID, tabID: tab.id, baseRevision: nil,
            origin: .appUser,
            operation: .open(content: .file(FileReference(path: "/b.txt")), placement: .automatic))
        let request = try RPCRequest(method: RPCMethod.panelApply, params: PanelApplyParams(envelope: envelope))
        let response = await router.handle(request)

        #expect(!response.success)
        #expect(response.error?.contains("daemon_panel_surface_enabled") == true)
    }

    @Test("panel.apply surfaces the agent-control gate by name")
    func applyAgentControlDisabledNamesFlag() async throws {
        let (router, db) = try makeRouterAndDB()
        try await db.config.setPanelSurfaceEnabled(true)
        // agent_panel_control_enabled left off.
        let wtID = try await makeWorktree(db)
        let tab = try await seedTab(db, worktreeID: wtID)

        let envelope = PanelOperationEnvelope(
            operationID: UUID(), worktreeID: wtID, tabID: tab.id, baseRevision: nil,
            origin: .agentCLI,
            operation: .open(content: .file(FileReference(path: "/b.txt")), placement: .automatic))
        let request = try RPCRequest(method: RPCMethod.panelApply, params: PanelApplyParams(envelope: envelope))
        let response = await router.handle(request)

        #expect(!response.success)
        #expect(response.error?.contains("agent_panel_control_enabled") == true)
    }

    // MARK: - panel.apply happy path (flag on, appUser) + panel.get reflects it

    @Test("panel.apply commits with the surface flag on and panel.get reflects it")
    func applyHappyPathThenGetReflectsResult() async throws {
        let (router, db) = try makeRouterAndDB()
        try await db.config.setPanelSurfaceEnabled(true)
        let wtID = try await makeWorktree(db)
        let tab = try await seedTab(db, worktreeID: wtID)

        let envelope = PanelOperationEnvelope(
            operationID: UUID(), worktreeID: wtID, tabID: tab.id, baseRevision: nil,
            origin: .appUser,
            operation: .open(content: .file(FileReference(path: "/b.txt")), placement: .automatic))
        let applyRequest = try RPCRequest(
            method: RPCMethod.panelApply, params: PanelApplyParams(envelope: envelope))
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

    // MARK: - panel.importLegacy dispatch (Task 11 implements the real behavior)

    @Test("panel.importLegacy route dispatches to a not-implemented error, not Unknown method")
    func importLegacyDispatchesToStub() async throws {
        let (router, _) = try makeRouterAndDB()
        let params = PanelImportParams(
            worktreeID: UUID(), tabs: [], tabOrder: [], activeTabID: nil, paneHistories: [:])
        let request = try RPCRequest(method: RPCMethod.panelImportLegacy, params: params)
        let response = await router.handle(request)
        #expect(!response.success)
        #expect(response.error?.contains("Unknown method") == false)
    }

    // MARK: - daemon.capabilities

    @Test("capabilities carries panelSurfaceEnabled")
    func capabilitiesCarriesPanelSurfaceFlag() async throws {
        let (router, db) = try makeRouterAndDB()

        var response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        var result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.panelSurfaceEnabled == false)

        try await db.config.setPanelSurfaceEnabled(true)
        response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.panelSurfaceEnabled == true)
    }

    /// Codable back-compat: capabilities JSON from a daemon without the new
    /// panelSurfaceEnabled key must still decode with a safe default.
    @Test("capabilities JSON without panelSurfaceEnabled decodes with default false")
    func capabilitiesDecodeBackCompat() throws {
        let json = Data(#"{"controlModeEnabled":true,"controlModeSupported":false}"#.utf8)
        let result = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: json)
        #expect(result.panelSurfaceEnabled == false)
    }
}
