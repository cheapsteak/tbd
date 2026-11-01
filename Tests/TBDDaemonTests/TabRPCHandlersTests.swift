import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import DaemonTestSupport
import TestSupport

@Suite struct TabRPCHandlersTests {

    private func makeRouter(db: TBDDatabase) -> RPCRouter {
        RPCRouter(
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
    }

    private func makeFixture() async throws -> (TBDDatabase, UUID) {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/tabrpc-repo-\(UUID().uuidString)",
            displayName: "T",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/tabrpc-repo/wt-\(UUID().uuidString)",
            tmuxServer: "tbd-tabrpc"
        )
        return (db, wt.id)
    }

    @Test func setLabelThenListReturnsIt() async throws {
        let (db, worktreeID) = try await makeFixture()
        let router = makeRouter(db: db)
        let tabID = UUID()

        // setLabel
        let setReq = try RPCRequest(
            method: RPCMethod.tabSetLabel,
            params: TabSetLabelParams(tabID: tabID, worktreeID: worktreeID, label: "My Tab")
        )
        let setResp = await router.handle(setReq)
        #expect(setResp.success)
        #expect(setResp.error == nil)

        // list
        let listReq = try RPCRequest(
            method: RPCMethod.tabList,
            params: TabListParams(worktreeID: worktreeID)
        )
        let listResp = await router.handle(listReq)
        #expect(listResp.success)
        let decoded = try listResp.decodeResult(TabListResponse.self)
        #expect(decoded.tabs.count == 1)
        #expect(decoded.tabs.first?.label == "My Tab")
        #expect(decoded.tabs.first?.id == tabID)
        #expect(decoded.order.isEmpty)
    }

    @Test func setLabelNilClearsRow() async throws {
        let (db, worktreeID) = try await makeFixture()
        let router = makeRouter(db: db)
        let tabID = UUID()
        let req = try RPCRequest(
            method: RPCMethod.tabSetLabel,
            params: TabSetLabelParams(tabID: tabID, worktreeID: worktreeID, label: nil)
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        #expect(resp.error == nil)
        let tabs = try await db.tabs.listForWorktree(worktreeID: worktreeID)
        #expect(tabs.isEmpty)
    }

    @Test func setOrderPersistsAndListReturnsIt() async throws {
        let (db, worktreeID) = try await makeFixture()
        let router = makeRouter(db: db)
        let ids = [UUID(), UUID(), UUID()]
        let req = try RPCRequest(
            method: RPCMethod.tabSetOrder,
            params: TabSetOrderParams(worktreeID: worktreeID, tabIDs: ids)
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        #expect(resp.error == nil)

        let listReq = try RPCRequest(
            method: RPCMethod.tabList,
            params: TabListParams(worktreeID: worktreeID)
        )
        let listResp = await router.handle(listReq)
        let decoded = try listResp.decodeResult(TabListResponse.self)
        #expect(decoded.order == ids)
    }

    @Test func setOrderRejectsDuplicates() async throws {
        let (db, worktreeID) = try await makeFixture()
        let router = makeRouter(db: db)
        let dup = UUID()
        let req = try RPCRequest(
            method: RPCMethod.tabSetOrder,
            params: TabSetOrderParams(worktreeID: worktreeID, tabIDs: [dup, dup])
        )
        let resp = await router.handle(req)
        #expect(!resp.success)
        #expect(resp.error != nil)
    }

    @Test func deletingTerminalDeletesItsTabRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/cleanup-t-repo-\(UUID().uuidString)",
            displayName: "C", defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/cleanup-t-repo/wt-\(UUID().uuidString)",
            tmuxServer: "tbd-cleanup-t"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1"
        )
        try await db.tabs.setLabel(tabID: terminal.id, worktreeID: wt.id, label: "Mine")

        let router = makeRouter(db: db)
        let req = try RPCRequest(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: terminal.id)
        )
        _ = await router.handle(req)
        let tabs = try await db.tabs.listForWorktree(worktreeID: wt.id)
        #expect(tabs.isEmpty)
    }

    @Test func setActiveTabPersistsAndTabListReturnsIt() async throws {
        let (db, worktreeID) = try await makeFixture()
        let router = makeRouter(db: db)
        let tabID = UUID()

        // Initially tab.list reports activeTabID = nil.
        let initialListReq = try RPCRequest(
            method: RPCMethod.tabList,
            params: TabListParams(worktreeID: worktreeID)
        )
        let initialResp = await router.handle(initialListReq)
        #expect(initialResp.success)
        let initialDecoded = try initialResp.decodeResult(TabListResponse.self)
        #expect(initialDecoded.activeTabID == nil)

        // worktree.setActiveTab writes the ID.
        let setReq = try RPCRequest(
            method: RPCMethod.worktreeSetActiveTab,
            params: WorktreeSetActiveTabParams(worktreeID: worktreeID, tabID: tabID)
        )
        let setResp = await router.handle(setReq)
        #expect(setResp.success)
        #expect(setResp.error == nil)

        // Subsequent tab.list returns it.
        let listReq = try RPCRequest(
            method: RPCMethod.tabList,
            params: TabListParams(worktreeID: worktreeID)
        )
        let listResp = await router.handle(listReq)
        let decoded = try listResp.decodeResult(TabListResponse.self)
        #expect(decoded.activeTabID == tabID)

        // nil clears.
        let clearReq = try RPCRequest(
            method: RPCMethod.worktreeSetActiveTab,
            params: WorktreeSetActiveTabParams(worktreeID: worktreeID, tabID: nil)
        )
        _ = await router.handle(clearReq)
        let clearedResp = await router.handle(listReq)
        let clearedDecoded = try clearedResp.decodeResult(TabListResponse.self)
        #expect(clearedDecoded.activeTabID == nil)
    }

    @Test func deletingNoteDeletesItsTabRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/cleanup-n-repo-\(UUID().uuidString)",
            displayName: "C", defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/cleanup-n-repo/wt-\(UUID().uuidString)",
            tmuxServer: "tbd-cleanup-n"
        )
        let note = try await db.notes.create(worktreeID: wt.id)
        try await db.tabs.setLabel(tabID: note.id, worktreeID: wt.id, label: "MyNote")

        let router = makeRouter(db: db)
        let req = try RPCRequest(
            method: RPCMethod.noteDelete,
            params: NoteDeleteParams(noteID: note.id)
        )
        _ = await router.handle(req)
        let tabs = try await db.tabs.listForWorktree(worktreeID: wt.id)
        #expect(tabs.isEmpty)
    }

    /// `note.delete` takes the note's worktree panel with it: no surface and
    /// no `worktree_panel` row shows the note afterwards, one delta carries
    /// every rewritten surface, and the note's tab row still goes.
    @Test func noteDeleteRemovesItsPanel() async throws {
        let (db, worktreeID) = try await makeFixture()
        let recorder = BroadcastRecorder()
        let subscriptions = StateSubscriptionManager()
        subscriptions.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                recorder.record(delta)
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
            subscriptions: subscriptions,
            actuationLog: makeTestActuationLog()
        )
        let note = try await db.notes.create(worktreeID: worktreeID)
        try await db.tabs.setLabel(tabID: note.id, worktreeID: worktreeID, label: "MyNote")
        let tabIDs = [UUID(), UUID()]
        for (position, tabID) in tabIDs.enumerated() {
            let surface = WorkspaceTabSurface(
                id: tabID, worktreeID: worktreeID, primary: .terminal(terminalID: UUID()))
            try await db.panelSurface.commit(surface: surface, position: position, receipt: nil, now: Date())
        }
        _ = try await db.panelSurface.openWorktreePanel(
            worktreeID: worktreeID, content: .note(noteID: note.id), now: Date())
        let deltasBefore = recorder.count

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.noteDelete, params: NoteDeleteParams(noteID: note.id)))

        #expect(response.success)
        #expect(try await db.notes.get(id: note.id) == nil)
        #expect(try await db.tabs.listForWorktree(worktreeID: worktreeID).isEmpty)
        #expect(try await db.panelSurface.worktreePanels(worktreeID: worktreeID).isEmpty)
        let rowCount = try await db.writerForTests.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM worktree_panel") ?? -1
        }
        #expect(rowCount == 0)
        let surfaces = try await db.panelSurface.surfaces(worktreeID: worktreeID)
        #expect(surfaces.map(\.id) == tabIDs)
        let noteShown = surfaces.contains { $0.worktreePanel(showing: .note(noteID: note.id)) != nil }
        #expect(!noteShown)
        let panelDeltas: [PanelSurfaceDelta] = recorder.deltas.dropFirst(deltasBefore).compactMap {
            if case .panelSurfaceChanged(let delta) = $0 { return delta }
            return nil
        }
        try #require(panelDeltas.count == 1)
        #expect(panelDeltas[0].worktreeID == worktreeID)
        #expect(panelDeltas[0].tabs == surfaces)
    }
}
