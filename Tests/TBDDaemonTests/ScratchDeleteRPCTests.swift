import Testing
import TestSupport
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

extension TBDHomeSerialized {
@Suite("scratch.delete RPC")
struct ScratchDeleteRPCTests {
    private func isolateTBDHome() -> (URL, () -> Void) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-scratchdel-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let priorTBDHome = setTBDHome(home.path)
        return (home, { restoreTBDHome(priorTBDHome); try? FileManager.default.removeItem(at: home) })
    }

    @Test func deletesRowAndTrashesFolder() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date())
        let created = await router.handle(try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: "gone")))
        let wt = try created.decodeResult(Worktree.self)
        #expect(FileManager.default.fileExists(atPath: wt.path))

        let del = await router.handle(try RPCRequest(method: RPCMethod.scratchDelete, params: ScratchDeleteParams(worktreeID: wt.id)))
        #expect(del.success)
        #expect(try await db.worktrees.get(id: wt.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: wt.path))  // moved to Trash
    }

    @Test func closesTerminalsAndTabsBeforeDeleting() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date())
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

        let del = await router.handle(try RPCRequest(method: RPCMethod.scratchDelete, params: ScratchDeleteParams(worktreeID: wt.id)))
        #expect(del.success)
        #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty)
        #expect(try await db.tabs.listForWorktree(worktreeID: wt.id).isEmpty)
        #expect(try await db.worktrees.get(id: wt.id) == nil)
    }

    /// Forces `FileManager.trashItem` to fail deterministically by stripping
    /// write permission from the scratch space's *parent* directory (trashItem
    /// must remove the entry from its containing directory, so a read-only
    /// parent reliably yields NSCocoaErrorDomain 513 "couldn't be moved to the
    /// trash"). Verifies the finding-1 fix: on trash failure the row survives
    /// and an error is returned, instead of silently deleting the row while
    /// orphaning the folder.
    @Test func keepsRowWhenTrashFails() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date())
        let created = await router.handle(try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: "undeletable")))
        let wt = try created.decodeResult(Worktree.self)

        let parent = TBDConstants.scratchDir
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }

        let del = await router.handle(try RPCRequest(method: RPCMethod.scratchDelete, params: ScratchDeleteParams(worktreeID: wt.id)))
        #expect(!del.success)
        #expect(del.error != nil)
        #expect(try await db.worktrees.get(id: wt.id) != nil)  // row survives so a retry is possible
        #expect(FileManager.default.fileExists(atPath: wt.path))  // folder untouched
    }

    /// Medium-1 review finding: `scratch.delete` must reclaim the scratch
    /// space's Claude Code scratchpad before the row disappears — once the
    /// row is gone, reconciliation has no path left to resolve it by.
    @Test func deletesAssociatedScratchpadWhenGCEnabled() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date())

        let scratchpadBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-scratchdel-claudebase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchpadBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchpadBase) }
        router.orphanGC = OrphanGC(
            db: db, git: GitManager(), broadcast: { _ in }, lsofProvider: { [] }, scratchpadBase: scratchpadBase)

        let created = await router.handle(try RPCRequest(
            method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: "with-claude-scratchpad")))
        let wt = try created.decodeResult(Worktree.self)

        let slug = ScratchpadCollector.slug(forWorktreePath: wt.path)
        let claudeScratchDir = scratchpadBase.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: claudeScratchDir, withIntermediateDirectories: true)
        try "hi".write(to: claudeScratchDir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let del = await router.handle(try RPCRequest(method: RPCMethod.scratchDelete, params: ScratchDeleteParams(worktreeID: wt.id)))
        #expect(del.success)
        #expect(
            !FileManager.default.fileExists(atPath: claudeScratchDir.path),
            "the Claude Code scratchpad must be reclaimed, not left orphaned once the row is gone"
        )
        let records = try await db.reapRecords.list(repoPath: nil)
        #expect(records.contains { $0.kind == .scratchpad && $0.worktreePath == claudeScratchDir.path })
    }

    /// The `gcEnabled` master switch must suppress this event-driven cleanup
    /// too, same as every other GC deletion path.
    @Test func leavesScratchpadIntactWhenGCDisabled() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(false)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date())

        let scratchpadBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-scratchdel-claudebase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchpadBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchpadBase) }
        router.orphanGC = OrphanGC(
            db: db, git: GitManager(), broadcast: { _ in }, lsofProvider: { [] }, scratchpadBase: scratchpadBase)

        let created = await router.handle(try RPCRequest(
            method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: "with-claude-scratchpad-disabled")))
        let wt = try created.decodeResult(Worktree.self)

        let slug = ScratchpadCollector.slug(forWorktreePath: wt.path)
        let claudeScratchDir = scratchpadBase.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: claudeScratchDir, withIntermediateDirectories: true)

        let del = await router.handle(try RPCRequest(method: RPCMethod.scratchDelete, params: ScratchDeleteParams(worktreeID: wt.id)))
        #expect(del.success)
        #expect(
            FileManager.default.fileExists(atPath: claudeScratchDir.path),
            "gcEnabled=false must suppress the scratchpad cleanup too"
        )
    }

    @Test func rejectsNonScratchWorktree() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date())
        let repo = try await db.repos.create(path: "/tmp/r-\(UUID().uuidString)", displayName: "r", defaultBranch: "main")
        let wt = try await db.worktrees.create(repoID: repo.id, name: "w", branch: "b",
                                               path: "/tmp/w-\(UUID().uuidString)", tmuxServer: "tbd-x")
        let del = await router.handle(try RPCRequest(method: RPCMethod.scratchDelete, params: ScratchDeleteParams(worktreeID: wt.id)))
        #expect(!del.success)
    }
}
}
