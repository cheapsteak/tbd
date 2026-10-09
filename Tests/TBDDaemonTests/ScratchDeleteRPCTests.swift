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
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())
        let created = await router.handle(try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: "gone")))
        let wt = try created.decodeResult(Worktree.self)
        #expect(FileManager.default.fileExists(atPath: wt.localPath))

        let del = await router.handle(try RPCRequest(method: RPCMethod.scratchDelete, params: ScratchDeleteParams(worktreeID: wt.id)))
        #expect(del.success)
        #expect(try await db.worktrees.get(id: wt.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: wt.localPath))  // moved to Trash
    }

    @Test func closesTerminalsAndTabsBeforeDeleting() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())
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
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())
        let created = await router.handle(try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: "undeletable")))
        let wt = try created.decodeResult(Worktree.self)

        let parent = TBDConstants.scratchDir
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }

        let del = await router.handle(try RPCRequest(method: RPCMethod.scratchDelete, params: ScratchDeleteParams(worktreeID: wt.id)))
        #expect(!del.success)
        #expect(del.error != nil)
        #expect(try await db.worktrees.get(id: wt.id) != nil)  // row survives so a retry is possible
        #expect(FileManager.default.fileExists(atPath: wt.localPath))  // folder untouched
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
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())

        let scratchpadBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-scratchdel-claudebase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchpadBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchpadBase) }
        router.orphanGC = OrphanGC(
            db: db, git: GitManager(), broadcast: { _ in }, lsofProvider: { [] }, scratchpadBase: scratchpadBase)

        let created = await router.handle(try RPCRequest(
            method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: "with-claude-scratchpad")))
        let wt = try created.decodeResult(Worktree.self)

        let slug = ScratchpadCollector.slug(forWorktreePath: wt.localPath)
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
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())

        let scratchpadBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-scratchdel-claudebase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchpadBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchpadBase) }
        router.orphanGC = OrphanGC(
            db: db, git: GitManager(), broadcast: { _ in }, lsofProvider: { [] }, scratchpadBase: scratchpadBase)

        let created = await router.handle(try RPCRequest(
            method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: "with-claude-scratchpad-disabled")))
        let wt = try created.decodeResult(Worktree.self)

        let slug = ScratchpadCollector.slug(forWorktreePath: wt.localPath)
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
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())
        let repo = try await db.repos.create(path: "/tmp/r-\(UUID().uuidString)", displayName: "r", defaultBranch: "main")
        let wt = try await db.worktrees.create(repoID: repo.id, name: "w", branch: "b",
                                               path: "/tmp/w-\(UUID().uuidString)", tmuxServer: "tbd-x")
        let del = await router.handle(try RPCRequest(method: RPCMethod.scratchDelete, params: ScratchDeleteParams(worktreeID: wt.id)))
        #expect(!del.success)
    }

    // MARK: - The holder transport

    /// `closeScratchTerminals` kills tmux windows and then deletes the rows.
    /// A holder row's `tmuxWindowID` is the empty string by construction, so
    /// that kill addressed nothing while the holder, the job it forked and its
    /// rendezvous files outlived the row that was the only record of their
    /// pids — and no sweep covers them until Milestone B's holder reconciler.
    /// It is the same branch, for the same reason, as `handleTerminalDelete`:
    /// the row goes away either way, so refusing would cause the leak rather
    /// than prevent it.
    ///
    /// The observable is `adoptAll`'s recorded status, which nothing but
    /// `abandon` clears. A row that merely vanished leaves it set.
    ///
    /// This gate's siblings — worktree archive and forget — live in
    /// `HolderTmuxAssumptionGateTests`, which needs no `TBD_HOME`.
    @Test func scratchDeleteDisposesHolderInsteadOfKillingAWindow() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        // Reports every window dead, which is what a real server answers for
        // the empty window id, and records every argv it is handed.
        let tmux = TmuxManager(
            dryRun: true, dryRunRecorder: { recorded.append($0) },
            dryRunWindowIsDead: { _ in true })
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux, startTime: Date(), actuationLog: makeTestActuationLog())
        let created = await router.handle(try RPCRequest(
            method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: "holder-scratch")))
        let wt = try created.decodeResult(Worktree.self)
        // `scratch.create` auto-spawns a primary agent terminal; clear it so
        // this test controls its own fixture.
        try await db.terminals.deleteForWorktree(worktreeID: wt.id)

        // `childPID: 0` deliberately: it is the one value the registry's
        // disposal refuses to signal, and any other value a fixture could name
        // is a pid this shared box may really be running.
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "", tmuxPaneID: "",
            kind: .claude, transport: .holder, holderPID: 9101, childPID: 0)
        let registry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": "/tmp/tbd-sd-\(UUID().uuidString.prefix(8))"],
            listTerminals: { [terminal] })
        // Nothing answers at the derived rendezvous, so the startup sweep
        // records the session as ended with an unknown status. That recorded
        // status is what separates "the row went away" from "the holder was
        // disposed of".
        _ = await registry.adoptAll()
        let armed = await registry.lastKnownStatus(for: terminal.id)
        #expect(armed == .exitedStatusUnknown, "the fixture never armed the observable")
        router.holderRegistry = registry

        let del = await router.handle(try RPCRequest(
            method: RPCMethod.scratchDelete, params: ScratchDeleteParams(worktreeID: wt.id)))

        #expect(del.success, "error: \(del.error ?? "nil")")
        #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty)
        let disposed = await registry.lastKnownStatus(for: terminal.id)
        #expect(disposed == nil,
                "scratch.delete removed the row without disposing of its holder, so the holder, its child and its rendezvous files are now owned by nothing")
        #expect(recorded.snapshot().contains { $0.contains("kill-window") } == false,
                "scratch.delete reached tmux kill-window for a holder row: \(recorded.snapshot())")
    }

    /// A scratch space whose only terminal is a holder row, on a router whose
    /// registry has recorded that session as ended — the observable only
    /// `abandon` clears. Shared by the Closed Terminals history tests below.
    private func holderScratch(
        name: String
    ) async throws -> (RPCRouter, TBDDatabase, Worktree, Terminal, HolderRegistry) {
        let db = try TBDDatabase(inMemory: true)
        let tmux = TmuxManager(dryRun: true, dryRunWindowIsDead: { _ in true })
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux, startTime: Date(), actuationLog: makeTestActuationLog())
        let created = await router.handle(try RPCRequest(
            method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: name)))
        let wt = try created.decodeResult(Worktree.self)
        try await db.terminals.deleteForWorktree(worktreeID: wt.id)
        // `childPID: 0`: see `scratchDeleteDisposesHolderInsteadOfKillingAWindow`.
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "", tmuxPaneID: "",
            claudeSessionID: "sess-scratch-holder",
            kind: .claude, transport: .holder, holderPID: 9101, childPID: 0)
        let registry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": "/tmp/tbd-sd-\(UUID().uuidString.prefix(8))"],
            listTerminals: { [terminal] })
        _ = await registry.adoptAll()
        let armed = await registry.lastKnownStatus(for: terminal.id)
        #expect(armed == .exitedStatusUnknown, "the fixture never armed the observable")
        router.holderRegistry = registry
        return (router, db, wt, terminal, registry)
    }

    /// Archive keeps the scratch space's history, so a holder row gets its
    /// Closed Terminals entry before the disposal releases the reader — the
    /// same as a repo worktree's archive. Nothing answers at the rendezvous, so
    /// there is no live screen and the entry carries no capture; it carries
    /// the Claude session id revive resumes by.
    @Test func scratchArchiveWritesAHolderRowsClosedTerminalsEntry() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let (router, db, wt, terminal, registry) = try await holderScratch(name: "holder-archive")

        let archived = await router.handle(try RPCRequest(
            method: RPCMethod.scratchArchive, params: ScratchArchiveParams(worktreeID: wt.id)))

        #expect(archived.success, "error: \(archived.error ?? "nil")")
        #expect(try await db.worktrees.get(id: wt.id)?.status == .archived)
        #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty)
        let disposed = await registry.lastKnownStatus(for: terminal.id)
        #expect(disposed == nil, "scratch.archive removed the row without disposing of its holder")
        let entries = try await db.terminalHistory.list(worktreeID: wt.id)
        #expect(entries.map(\.id) == [terminal.id],
                "scratch.archive disposed a holder row without writing its Closed Terminals entry")
        #expect(entries.first?.kind == .claude)
        #expect(entries.first?.claudeSessionID == "sess-scratch-holder")
        #expect(entries.first?.lineCount == 0)
    }

    /// Delete hard-deletes the history right after the teardown, so the
    /// teardown writes no entry for it to wipe. Asserted on the teardown
    /// itself: through the RPC the hard delete would empty the table either
    /// way, and the assertion would pass whether or not the entry was written.
    @Test func scratchDeleteTeardownWritesNoHolderClosedTerminalsEntry() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let (router, db, wt, terminal, registry) = try await holderScratch(name: "holder-delete")

        try await router.closeScratchTerminals(wt, keepsHistory: false)

        #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty)
        let disposed = await registry.lastKnownStatus(for: terminal.id)
        #expect(disposed == nil, "the delete teardown removed the row without disposing of its holder")
        #expect(try await db.terminalHistory.list(worktreeID: wt.id).isEmpty,
                "the delete teardown wrote a Closed Terminals entry the hard delete is about to wipe")
    }

    /// The other leg. An inverted transport comparison would leave a real tmux
    /// window running while its row was deleted.
    @Test func scratchDeleteStillKillsAnIdenticalTmuxWindow() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = TmuxManager(
            dryRun: true, dryRunRecorder: { recorded.append($0) },
            dryRunWindowIsDead: { _ in true })
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux, startTime: Date(), actuationLog: makeTestActuationLog())
        let created = await router.handle(try RPCRequest(
            method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: "tmux-scratch")))
        let wt = try created.decodeResult(Worktree.self)
        try await db.terminals.deleteForWorktree(worktreeID: wt.id)
        _ = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@7", tmuxPaneID: "%7", kind: .claude)
        // Wired in and listing nothing, so an inverted comparison reaches a
        // registry that has never heard of this row rather than a nil that
        // would make the branch unreachable either way.
        router.holderRegistry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": "/tmp/tbd-sd-\(UUID().uuidString.prefix(8))"],
            listTerminals: { [] })

        let del = await router.handle(try RPCRequest(
            method: RPCMethod.scratchDelete, params: ScratchDeleteParams(worktreeID: wt.id)))

        #expect(del.success, "error: \(del.error ?? "nil")")
        let argv = recorded.snapshot()
        #expect(argv.contains { $0.contains("kill-window") && $0.contains("@7") },
                "the tmux leg must still kill its own window: \(argv)")
    }
}
}
