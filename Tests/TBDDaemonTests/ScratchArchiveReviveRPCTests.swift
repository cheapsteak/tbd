import Testing
import TestSupport
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

extension TBDHomeSerialized {
@Suite("scratch.archive / scratch.revive RPC")
struct ScratchArchiveReviveRPCTests {
    private func isolateTBDHome() -> (URL, () -> Void) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-scratcharch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let priorTBDHome = setTBDHome(home.path)
        return (home, { restoreTBDHome(priorTBDHome); try? FileManager.default.removeItem(at: home) })
    }

    /// Router whose lifecycle and handlers share one StateSubscriptionManager,
    /// with every broadcast delta captured in `deltas`.
    private func makeRouter(db: TBDDatabase) -> (router: RPCRouter, deltas: BroadcastDeltas) {
        let deltas = BroadcastDeltas()
        let subs = StateSubscriptionManager()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            subscriptions: subs, actuationLog: makeTestActuationLog())
        return (router, deltas)
    }

    @Test func archiveFlipsStatusSetsArchivedAtAndLeavesFolder() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let (router, deltas) = makeRouter(db: db)
        let created = await router.handle(try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: "to-archive")))
        let wt = try created.decodeResult(Worktree.self)
        #expect(FileManager.default.fileExists(atPath: wt.localPath))

        let archive = await router.handle(try RPCRequest(method: RPCMethod.scratchArchive, params: ScratchArchiveParams(worktreeID: wt.id)))
        #expect(archive.success)

        let reloaded = try await db.worktrees.get(id: wt.id)
        #expect(reloaded?.status == .archived)
        #expect(reloaded?.archivedAt != nil)

        // Folder is left untouched on disk — unlike delete, no Trash move.
        #expect(FileManager.default.fileExists(atPath: wt.localPath))

        let archived = deltas.snapshot().filter {
            if case .worktreeArchived(let d) = $0 { return d.worktreeID == wt.id }
            return false
        }
        #expect(archived.count == 1)
    }

    @Test func archiveClosesTerminalsAndTabs() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let (router, _) = makeRouter(db: db)
        let created = await router.handle(try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: "with-terminal")))
        let wt = try created.decodeResult(Worktree.self)
        // The scratch.create RPC now auto-spawns a default primary agent terminal;
        // clear it so this test controls its own terminal fixture.
        try await db.terminals.deleteForWorktree(worktreeID: wt.id)

        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
        try await db.tabs.setLabel(tabID: terminal.id, worktreeID: wt.id, label: "my tab")

        #expect(try await db.terminals.list(worktreeID: wt.id).count == 1)
        #expect(try await db.tabs.listForWorktree(worktreeID: wt.id).count == 1)

        let archive = await router.handle(try RPCRequest(method: RPCMethod.scratchArchive, params: ScratchArchiveParams(worktreeID: wt.id)))
        #expect(archive.success)
        #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty)
        #expect(try await db.tabs.listForWorktree(worktreeID: wt.id).isEmpty)
    }

    @Test func archiveRejectsNonScratchWorktree() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let (router, _) = makeRouter(db: db)
        let repo = try await db.repos.create(path: "/tmp/r-\(UUID().uuidString)", displayName: "r", defaultBranch: "main")
        let wt = try await db.worktrees.create(repoID: repo.id, name: "w", branch: "b",
                                               path: "/tmp/w-\(UUID().uuidString)", tmuxServer: "tbd-x")
        let archive = await router.handle(try RPCRequest(method: RPCMethod.scratchArchive, params: ScratchArchiveParams(worktreeID: wt.id)))
        #expect(!archive.success)
    }

    @Test func reviveHappyPathFlipsBackToActiveAndClearsArchivedAt() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let (router, deltas) = makeRouter(db: db)
        let created = await router.handle(try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: "to-revive")))
        let wt = try created.decodeResult(Worktree.self)
        let archive = await router.handle(try RPCRequest(method: RPCMethod.scratchArchive, params: ScratchArchiveParams(worktreeID: wt.id)))
        #expect(archive.success)

        let revive = await router.handle(try RPCRequest(method: RPCMethod.scratchRevive, params: ScratchReviveParams(worktreeID: wt.id)))
        #expect(revive.success)

        let reloaded = try await db.worktrees.get(id: wt.id)
        #expect(reloaded?.status == .active)
        #expect(reloaded?.archivedAt == nil)

        let revived = deltas.snapshot().filter {
            if case .worktreeRevived(let d) = $0 { return d.worktreeID == wt.id }
            return false
        }
        #expect(revived.count == 1)
    }

    @Test func reviveWithMissingFolderReturnsErrorAndDoesNotFlipStatus() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let (router, _) = makeRouter(db: db)
        let created = await router.handle(try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: "to-vanish")))
        let wt = try created.decodeResult(Worktree.self)
        let archive = await router.handle(try RPCRequest(method: RPCMethod.scratchArchive, params: ScratchArchiveParams(worktreeID: wt.id)))
        #expect(archive.success)

        // Simulate the folder disappearing out from under the archived row.
        try FileManager.default.removeItem(atPath: wt.localPath)

        let revive = await router.handle(try RPCRequest(method: RPCMethod.scratchRevive, params: ScratchReviveParams(worktreeID: wt.id)))
        #expect(!revive.success)
        #expect(revive.error != nil)

        let reloaded = try await db.worktrees.get(id: wt.id)
        #expect(reloaded?.status == .archived)
    }

    @Test func deleteStillWorksOnAnAlreadyArchivedScratchRow() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let (router, _) = makeRouter(db: db)
        let created = await router.handle(try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: "archived-then-deleted")))
        let wt = try created.decodeResult(Worktree.self)
        let archive = await router.handle(try RPCRequest(method: RPCMethod.scratchArchive, params: ScratchArchiveParams(worktreeID: wt.id)))
        #expect(archive.success)
        // Terminals are already gone from the archive step — delete's cleanup
        // loop must be a no-op over zero terminals, not choke.
        #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty)

        let del = await router.handle(try RPCRequest(method: RPCMethod.scratchDelete, params: ScratchDeleteParams(worktreeID: wt.id)))
        #expect(del.success)
        #expect(try await db.worktrees.get(id: wt.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: wt.localPath))  // moved to Trash
    }
}
}

/// Thread-safe collector for broadcast StateDeltas.
private final class BroadcastDeltas: @unchecked Sendable {
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
