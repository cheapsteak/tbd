import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

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
            startTime: Date()
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
}
