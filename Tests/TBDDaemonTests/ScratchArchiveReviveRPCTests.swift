import Testing
import TestSupport
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

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

extension TBDHomeSerialized {
@Suite("scratch.archive / scratch.revive RPC")
struct ScratchArchiveReviveRPCTests {
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

/// `tbd worktree archive <scratch>` used to fail with "Repository not found:
/// <worktree id>": the repo-worktree archive path resolves a repo before doing
/// anything, and a scratch row has none. `worktree.archive` and
/// `worktree.revive` now route a repo-less row to the `scratch.*` body.
/// See `docs/specs/2026-08-20-scratch-archive-routing-design.md`.
extension TBDHomeSerialized {
@Suite("worktree.archive / worktree.revive on a scratch space")
struct WorktreeArchiveScratchRoutingRPCTests {

    private func makeScratch(
        _ router: RPCRouter, name: String
    ) async throws -> Worktree {
        let created = await router.handle(try RPCRequest(
            method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: name)))
        return try created.decodeResult(Worktree.self)
    }

    @Test func archiveSucceedsFlipsStatusAndLeavesFolderOnDisk() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let (router, deltas) = makeRouter(db: db)
        let wt = try await makeScratch(router, name: "wt-archive-me")
        #expect(FileManager.default.fileExists(atPath: wt.localPath))

        let archive = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeArchive,
            params: WorktreeArchiveParams(worktreeID: wt.id)))
        #expect(archive.success)
        // The old failure's exact wording, asserted so a regression that
        // reinstates the repo guard fails loudly rather than just unsuccessfully.
        #expect(archive.error == nil)

        let reloaded = try await db.worktrees.get(id: wt.id)
        #expect(reloaded?.status == .archived)
        #expect(reloaded?.archivedAt != nil)
        // Archived, not forgotten and not deleted: the row survives...
        #expect(reloaded != nil)
        // ...and so does the folder. `worktree.archive`'s phase 2 hands the
        // directory to the deletion queue; the scratch path must never do that.
        #expect(FileManager.default.fileExists(atPath: wt.localPath))

        let archived = deltas.snapshot().filter {
            if case .worktreeArchived(let d) = $0 { return d.worktreeID == wt.id }
            return false
        }
        #expect(archived.count == 1)
    }

    @Test func archivedScratchRowAppearsInTheArchivedListing() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let (router, _) = makeRouter(db: db)
        let wt = try await makeScratch(router, name: "wt-archive-listing")

        let archive = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeArchive,
            params: WorktreeArchiveParams(worktreeID: wt.id)))
        #expect(archive.success)

        let listed = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeList,
            params: WorktreeListParams(status: .archived)))
        let rows = try listed.decodeResult([Worktree].self)
        #expect(rows.contains { $0.id == wt.id })
    }

    @Test func reviveBringsTheArchivedScratchRowBackAndReturnsTheRow() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let (router, deltas) = makeRouter(db: db)
        let wt = try await makeScratch(router, name: "wt-revive-me")
        #expect(await router.handle(try RPCRequest(
            method: RPCMethod.worktreeArchive,
            params: WorktreeArchiveParams(worktreeID: wt.id))).success)

        let revive = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeRevive,
            params: WorktreeReviveParams(worktreeID: wt.id)))
        #expect(revive.success)
        // Both the CLI and the app client decode a `Worktree` from
        // `worktree.revive`'s result, so `.ok()` would break them.
        let returned = try revive.decodeResult(Worktree.self)
        #expect(returned.id == wt.id)
        #expect(returned.status == .active)
        #expect(returned.archivedAt == nil)

        let reloaded = try await db.worktrees.get(id: wt.id)
        #expect(reloaded?.status == .active)
        #expect(reloaded?.archivedAt == nil)

        let revived = deltas.snapshot().filter {
            if case .worktreeRevived(let d) = $0 { return d.worktreeID == wt.id }
            return false
        }
        // Exactly one: the helper broadcasts, and the routed branch returns
        // before the repo path's own broadcast.
        #expect(revived.count == 1)
    }

    @Test func archiveTearsDownTerminalsAndTabs() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let (router, _) = makeRouter(db: db)
        let wt = try await makeScratch(router, name: "wt-archive-terminals")
        // scratch.create auto-spawns a primary agent terminal; clear it so this
        // test owns its fixture.
        try await db.terminals.deleteForWorktree(worktreeID: wt.id)
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
        try await db.tabs.setLabel(tabID: terminal.id, worktreeID: wt.id, label: "my tab")

        #expect(await router.handle(try RPCRequest(
            method: RPCMethod.worktreeArchive,
            params: WorktreeArchiveParams(worktreeID: wt.id))).success)
        #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty)
        #expect(try await db.tabs.listForWorktree(worktreeID: wt.id).isEmpty)
    }

    @Test func forceIsAcceptedAndInertOnAScratchSpace() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let (router, _) = makeRouter(db: db)
        let wt = try await makeScratch(router, name: "wt-archive-forced")

        let archive = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeArchive,
            params: WorktreeArchiveParams(worktreeID: wt.id, force: true)))
        #expect(archive.success)
        #expect(try await db.worktrees.get(id: wt.id)?.status == .archived)
        // Still on disk: `force` skips the archive hook on the repo path, and
        // must not be read as license to remove anything here.
        #expect(FileManager.default.fileExists(atPath: wt.localPath))
    }

    @Test func reviveRefusesWhenTheFolderVanishedAndKeepsTheRowArchived() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let (router, _) = makeRouter(db: db)
        let wt = try await makeScratch(router, name: "wt-revive-vanished")
        #expect(await router.handle(try RPCRequest(
            method: RPCMethod.worktreeArchive,
            params: WorktreeArchiveParams(worktreeID: wt.id))).success)
        try FileManager.default.removeItem(atPath: wt.localPath)

        let revive = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeRevive,
            params: WorktreeReviveParams(worktreeID: wt.id)))
        #expect(!revive.success)
        #expect(revive.error?.contains("missing on disk") == true)
        #expect(try await db.worktrees.get(id: wt.id)?.status == .archived)
    }

    @Test func aRepoWorktreeStillTakesTheRepoPath() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let (router, _) = makeRouter(db: db)
        // The routing keys on `repoID == nil`. A row that HAS a repo must not
        // reach the scratch body: it would leave the directory and the git
        // registration behind while reporting success.
        let repo = try await db.repos.create(
            path: "/tmp/r-\(UUID().uuidString)", displayName: "r", defaultBranch: "main")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b", path: dir.path, tmuxServer: "tbd-x")
        #expect(!wt.isScratch)

        let archive = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeArchive,
            params: WorktreeArchiveParams(worktreeID: wt.id)))
        // Phase 1 succeeds against a real repo row; the point is that it went
        // through the lifecycle at all, which the scratch body would have
        // refused with "Not a scratch space".
        #expect(archive.error != "Not a scratch space: \(wt.id)")
    }
}
}

/// The message that shipped the bug read "Repository not found: <worktree id>":
/// one guard covered two different failures, and the `?? worktreeID` fallback
/// named an object nothing had looked up.
@Suite("WorktreeLifecycleError repo-less rendering")
struct WorktreeLifecycleRepoErrorMessageTests {
    @Test func aRepoLessRowRendersAsSuchAndNamesTheWorktree() {
        let worktreeID = UUID()
        let message = WorktreeLifecycleError.worktreeHasNoRepo(worktreeID).description
        #expect(message.contains(worktreeID.uuidString))
        #expect(message.lowercased().contains("no repository"))
        #expect(!message.contains("Repository not found"))
    }

    @Test func repoNotFoundStillMeansAMissingRepoRow() {
        let repoID = UUID()
        #expect(WorktreeLifecycleError.repoNotFound(repoID).description
            == "Repository not found: \(repoID)")
    }
}
