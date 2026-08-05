import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// `WorktreeStore.promoteScratchMigration` — the single-transaction row
/// migration behind `scratch.promote`. Pure in-memory-DB tests: no TBD_HOME,
/// no filesystem, no tmux.
@Suite("promoteScratchMigration atomicity")
struct ScratchPromoteAtomicityTests {

    @Test func midMigrationFailureLeavesPrePromoteStateIntact() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await db.worktrees.createScratch(
            name: "s", displayName: "s", path: "/tmp/tbd-atomicity-\(UUID())",
            tmuxServer: "tbd-scratch")
        let t1 = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "sess-1", kind: .claude)
        try await db.tabs.setLabel(tabID: t1.id, worktreeID: wt.id, label: "My Tab")
        try await db.worktrees.setTabOrder(worktreeID: wt.id, tabIDs: [t1.id])
        try await db.worktrees.setActiveTabID(worktreeID: wt.id, tabID: t1.id)

        // A bogus main-worktree ID fails inside the transaction (either the
        // terminal FK re-point or the main-row guard, depending on FK
        // enforcement) — the rollback must restore the full pre-promote state.
        await #expect(throws: (any Error).self) {
            try await db.worktrees.promoteScratchMigration(
                scratchID: wt.id, mainWorktreeID: UUID(), repoID: UUID(),
                tmuxServer: wt.tmuxServer)
        }

        // Scratch row un-promoted and still active — retryable.
        let scratchAfter = try #require(try await db.worktrees.get(id: wt.id))
        #expect(scratchAfter.status == .active)
        #expect(scratchAfter.promotedToRepoID == nil)
        // Terminals + tab state untouched (still parented to the scratch row,
        // so a later scratch.delete tears down exactly what it owns).
        #expect(try await db.terminals.list(worktreeID: wt.id).map(\.id) == [t1.id])
        #expect(try await db.tabs.listForWorktree(worktreeID: wt.id).map(\.label) == ["My Tab"])
        #expect(try await db.worktrees.getTabOrder(worktreeID: wt.id) == [t1.id])
        #expect(try await db.worktrees.getActiveTabID(worktreeID: wt.id) == t1.id)
    }

    @Test func successAppliesAllRowMutationsTogether() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/tbd-atomicity-repo-\(UUID())", displayName: "r", defaultBranch: "main")
        let repoID = repo.id
        let wt = try await db.worktrees.createScratch(
            name: "s", displayName: "s", path: "/tmp/tbd-atomicity-\(UUID())",
            tmuxServer: "tbd-scratch")
        let main = try await db.worktrees.createMain(
            repoID: repoID, name: "main", branch: "main",
            path: "/tmp/tbd-atomicity-main-\(UUID())", tmuxServer: "tbd-canonical")
        let t1 = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "sess-1", kind: .claude)
        try await db.tabs.setLabel(tabID: t1.id, worktreeID: wt.id, label: "My Tab")
        try await db.worktrees.setTabOrder(worktreeID: wt.id, tabIDs: [t1.id])
        try await db.worktrees.setActiveTabID(worktreeID: wt.id, tabID: t1.id)

        try await db.worktrees.promoteScratchMigration(
            scratchID: wt.id, mainWorktreeID: main.id, repoID: repoID,
            tmuxServer: wt.tmuxServer)

        let mainAfter = try #require(try await db.worktrees.get(id: main.id))
        #expect(mainAfter.tmuxServer == wt.tmuxServer)
        #expect(try await db.terminals.list(worktreeID: main.id).map(\.id) == [t1.id])
        #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty)
        #expect(try await db.tabs.listForWorktree(worktreeID: main.id).map(\.label) == ["My Tab"])
        #expect(try await db.worktrees.getTabOrder(worktreeID: main.id) == [t1.id])
        #expect(try await db.worktrees.getActiveTabID(worktreeID: main.id) == t1.id)
        let scratchAfter = try #require(try await db.worktrees.get(id: wt.id))
        #expect(scratchAfter.status == .archived)
        #expect(scratchAfter.promotedToRepoID == repoID)
    }
}

/// `terminal.create` must never parent a new terminal row to an archived
/// worktree — the orphan class behind the SessionStart-hook foreign-session
/// window. Store-level tests cover the race-proof in-transaction guard;
/// RPC-level tests cover each early-check branch.
@Suite("terminal.create archived-worktree guard")
struct TerminalCreateArchivedWorktreeGuardTests {

    private func makeRouter(_ db: TBDDatabase) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog()
        )
    }

    private func makeScratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-termguard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Store-level (in-transaction) guard

    @Test func storeAllowsInsertOnPlainArchivedWorktree() async throws {
        // The revive flow spawns terminals while the row is still `.archived`
        // (it flips `.active`/`.creating` only after the spawn succeeds), so
        // the store-level guard must reject ONLY promoted rows, never plain
        // archived ones.
        let db = try TBDDatabase(inMemory: true)
        let wt = try await db.worktrees.createScratch(
            name: "s", displayName: "s", path: "/tmp/x-\(UUID())", tmuxServer: "t")
        try await db.worktrees.archive(id: wt.id)

        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
        #expect(try await db.terminals.get(id: terminal.id) != nil)
    }

    @Test func storeRejectsInsertOnPromotedArchivedWorktree() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await db.worktrees.createScratch(
            name: "s", displayName: "s", path: "/tmp/x-\(UUID())", tmuxServer: "t")
        try await db.worktrees.setPromotedToRepoID(id: wt.id, repoID: UUID())
        try await db.worktrees.archive(id: wt.id)

        await #expect(throws: (any Error).self) {
            _ = try await db.terminals.create(
                worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
        }
        #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty)
    }

    @Test func storeAllowsInsertOnActiveWorktree() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await db.worktrees.createScratch(
            name: "s", displayName: "s", path: "/tmp/x-\(UUID())", tmuxServer: "t")

        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
        #expect(try await db.terminals.list(worktreeID: wt.id).map(\.id) == [terminal.id])
    }

    // MARK: RPC-level early checks

    @Test func rpcRejectsArchivedWorktree() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)
        let dir = try makeScratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wt = try await db.worktrees.createScratch(
            name: "s", displayName: "s", path: dir.path, tmuxServer: "t")
        try await db.worktrees.archive(id: wt.id)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id)))
        #expect(!resp.success)
        #expect(resp.error?.contains("archived") == true)
        #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty)
    }

    @Test func rpcRejectsPromotedWorktreeWithGuidance() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)
        let dir = try makeScratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let promotedRepoID = UUID()
        let wt = try await db.worktrees.createScratch(
            name: "s", displayName: "s", path: dir.path, tmuxServer: "t")
        try await db.worktrees.setPromotedToRepoID(id: wt.id, repoID: promotedRepoID)
        try await db.worktrees.archive(id: wt.id)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id)))
        #expect(!resp.success)
        #expect(resp.error?.contains("promoted") == true)
        #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty)
    }

    @Test func rpcCreatesShellTerminalOnActiveWorktree() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)
        let dir = try makeScratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wt = try await db.worktrees.createScratch(
            name: "s", displayName: "s", path: dir.path, tmuxServer: "t")

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id)))
        #expect(resp.success)
        let terminal = try resp.decodeResult(Terminal.self)
        #expect(terminal.worktreeID == wt.id)
        #expect(try await db.terminals.get(id: terminal.id) != nil)
    }
}
