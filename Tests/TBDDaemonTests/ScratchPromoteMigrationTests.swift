import Testing
import TestSupport
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

// Nested under TBDHomeSerialized: scratch.create/promote resolve
// TBDConstants.scratchDir from the process-global TBD_HOME, and the wake tests
// set TBD_CLAUDE_HOST_HOME so the ambient projects root never points at the
// developer's real ~/.claude. See TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {

/// scratch.promote metadata migration: terminals re-parented, tmux server
/// carried, tab state migrated, scratch row archived, Claude project dirs
/// snapshotted (copy-if-newer).
@Suite("scratch.promote metadata migration")
struct ScratchPromoteMigrationTests {
    private func isolate() -> (URL, () -> Void) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-promote-mig-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let priorTBDHome = setTBDHome(home.path)
        let priorClaudeHost = setClaudeHostHome(home.appendingPathComponent("claude-host").path)
        return (home, {
            restoreTBDHome(priorTBDHome)
            restoreClaudeHostHome(priorClaudeHost)
            try? FileManager.default.removeItem(at: home)
        })
    }

    /// Router with a fully isolated Claude config-dir manager: profile config
    /// dirs under `<home>/profiles/`, ambient host dir `<home>/claude-host/`.
    private func makeRouter(_ db: TBDDatabase, home: URL) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            configDirManager: ClaudeProfileConfigDirManager(
                baseDirectory: home.appendingPathComponent("profiles", isDirectory: true),
                hostBaseDirectory: home.appendingPathComponent("claude-host", isDirectory: true)
            )
        )
    }

    private func gitInitCommit(at path: String) throws {
        for args in [["init"], ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"]] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", path] + args; try p.run(); p.waitUntilExit()
        }
    }

    private func writeFile(_ text: String, to url: URL, mtime: Date? = nil) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
    }

    @Test func promoteMigratesTerminalsTabsAndTmuxServerAndArchivesScratchRow() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db, home: home)

        let created = await router.handle(try RPCRequest(
            method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: nil)))
        let wt = try created.decodeResult(Worktree.self)
        try gitInitCommit(at: wt.path)
        // The scratch.create RPC now auto-spawns a default primary agent terminal;
        // clear it so this test controls its own terminal fixture.
        try await db.terminals.deleteForWorktree(worktreeID: wt.id)

        // Two live-ish terminals, a labeled tab, an order, and a selection.
        let t1 = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "sess-1", kind: .claude)
        let t2 = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: "shell", kind: .shell)
        try await db.tabs.setLabel(tabID: t1.id, worktreeID: wt.id, label: "My Tab")
        try await db.worktrees.setTabOrder(worktreeID: wt.id, tabIDs: [t2.id, t1.id])
        try await db.worktrees.setActiveTabID(worktreeID: wt.id, tabID: t2.id)

        let dest = home.appendingPathComponent("projects/promoted-app").path
        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.scratchPromote,
            params: ScratchPromoteParams(worktreeID: wt.id, destPath: dest, displayName: nil)))
        #expect(resp.success)
        let result = try resp.decodeResult(ScratchPromoteResult.self)

        // The new repo's main worktree exists and inherited the scratch tmux server.
        let mainWt = try #require(
            try await db.worktrees.list(repoID: result.repoID, status: .main).first)
        #expect(mainWt.tmuxServer == wt.tmuxServer)

        // Terminals re-parented; none left on the scratch row.
        let migrated = try await db.terminals.list(worktreeID: mainWt.id)
        #expect(Set(migrated.map(\.id)) == [t1.id, t2.id])
        #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty)

        // Live-session invariant: identity untouched — same session id and no
        // transcriptPath rewrite (it was nil and must stay nil).
        let migratedT1 = try #require(migrated.first(where: { $0.id == t1.id }))
        #expect(migratedT1.claudeSessionID == "sess-1")
        #expect(migratedT1.transcriptPath == nil)

        // Tab state carried: rows re-pointed, order + selection copied.
        let tabs = try await db.tabs.listForWorktree(worktreeID: mainWt.id)
        #expect(tabs.map(\.label) == ["My Tab"])
        #expect(try await db.tabs.listForWorktree(worktreeID: wt.id).isEmpty)
        #expect(try await db.worktrees.getTabOrder(worktreeID: mainWt.id) == [t2.id, t1.id])
        #expect(try await db.worktrees.getActiveTabID(worktreeID: mainWt.id) == t2.id)

        // Scratch row retired: archived AND still pointing at the repo.
        let scratchRow = try #require(try await db.worktrees.get(id: wt.id))
        #expect(scratchRow.status == .archived)
        #expect(scratchRow.promotedToRepoID == result.repoID)
    }

    @Test func promoteSnapshotsClaudeProjectDirsPerRootWithCopyIfNewer() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db, home: home)

        let created = await router.handle(try RPCRequest(
            method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: nil)))
        let wt = try created.decodeResult(Worktree.self)
        try gitInitCommit(at: wt.path)
        // The scratch.create RPC now auto-spawns a default primary agent terminal;
        // clear it so this test controls its own terminal fixture.
        try await db.terminals.deleteForWorktree(worktreeID: wt.id)

        // One ambient terminal and one profile-pinned terminal.
        let profileID = UUID()
        _ = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "amb-1", kind: .claude)
        _ = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: "claude", claudeSessionID: "prof-1", profileID: profileID, kind: .claude)

        // Seed the OLD munged dirs under both projects roots.
        let ambientRoot = home.appendingPathComponent("claude-host/projects", isDirectory: true)
        let profileRoot = home.appendingPathComponent(
            "profiles/\(profileID.uuidString.lowercased())/claude/projects", isDirectory: true)
        let oldAmbient = TranscriptProjectDirSync.derivedProjectDir(
            worktreePath: wt.path, projectsRoot: ambientRoot)
        let oldProfile = TranscriptProjectDirSync.derivedProjectDir(
            worktreePath: wt.path, projectsRoot: profileRoot)
        try writeFile("ambient transcript", to: oldAmbient.appendingPathComponent("amb-1.jsonl"))
        try writeFile("sub", to: oldAmbient.appendingPathComponent("amb-1/subagents/agent-a.jsonl"))
        try writeFile("remember me", to: oldAmbient.appendingPathComponent("memory/MEMORY.md"))
        // Copy-if-newer: a second session already has FRESHER content at the
        // destination — the snapshot must not clobber it.
        try writeFile("stale old", to: oldAmbient.appendingPathComponent("amb-2.jsonl"),
                      mtime: Date(timeIntervalSinceNow: -600))
        try writeFile("profile transcript", to: oldProfile.appendingPathComponent("prof-1.jsonl"))
        ClaudeProjectDirectory.clearCache()

        let dest = home.appendingPathComponent("projects/promoted-app").path
        let newAmbient = TranscriptProjectDirSync.derivedProjectDir(
            worktreePath: dest, projectsRoot: ambientRoot)
        let newProfile = TranscriptProjectDirSync.derivedProjectDir(
            worktreePath: dest, projectsRoot: profileRoot)
        try writeFile("fresh forked", to: newAmbient.appendingPathComponent("amb-2.jsonl"),
                      mtime: Date())

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.scratchPromote,
            params: ScratchPromoteParams(worktreeID: wt.id, destPath: dest, displayName: nil)))
        #expect(resp.success)

        // Session JSONLs, subagents contents, and memory/ appear under the new
        // munged dirs for BOTH roots; the fresher destination file survives.
        #expect(try String(
            contentsOf: newAmbient.appendingPathComponent("amb-1.jsonl"), encoding: .utf8)
            == "ambient transcript")
        #expect(try String(
            contentsOf: newAmbient.appendingPathComponent("amb-1/subagents/agent-a.jsonl"),
            encoding: .utf8) == "sub")
        #expect(try String(
            contentsOf: newAmbient.appendingPathComponent("memory/MEMORY.md"), encoding: .utf8)
            == "remember me")
        #expect(try String(
            contentsOf: newAmbient.appendingPathComponent("amb-2.jsonl"), encoding: .utf8)
            == "fresh forked")
        #expect(try String(
            contentsOf: newProfile.appendingPathComponent("prof-1.jsonl"), encoding: .utf8)
            == "profile transcript")
    }
}

/// Wake path guard + pre-resume transcript sync (HibernationCoordinator).
@Suite("wake path guard and pre-resume sync")
struct WakePathGuardTests {
    private func isolate() -> (URL, () -> Void) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-wake-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let priorTBDHome = setTBDHome(home.path)
        let priorClaudeHost = setClaudeHostHome(home.appendingPathComponent("claude-host").path)
        return (home, {
            restoreTBDHome(priorTBDHome)
            restoreClaudeHostHome(priorClaudeHost)
            try? FileManager.default.removeItem(at: home)
        })
    }

    private func makeRouter(_ db: TBDDatabase) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date()
        )
    }

    @Test func wakeRefusesWhenWorktreePathMissingOnDisk() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)

        let missingPath = home.appendingPathComponent("never-created").path
        let wt = try await db.worktrees.createScratch(
            name: "gone", displayName: "gone", path: missingPath, tmuxServer: "tbd-test")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "sess-1", kind: .claude)
        try await db.terminals.setHibernated(id: terminal.id, sessionID: "sess-1")

        let result = await router.hibernationCoordinator.wake(terminalID: terminal.id)

        // Dedicated case carrying the missing path — the RPC layer surfaces it
        // as an actionable message instead of a generic "Terminal not found".
        #expect(result == .worktreeMissing(path: missingPath))
        // Row stays parked so a later retry (after the path is restored) works.
        #expect(try await db.terminals.get(id: terminal.id)?.hibernatedAt != nil)
    }

    @Test func wakeSucceedsAndSyncsTranscriptIntoDerivedDirForExistingPath() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)

        let wtDir = home.appendingPathComponent("wt", isDirectory: true)
        try FileManager.default.createDirectory(at: wtDir, withIntermediateDirectories: true)
        let wt = try await db.worktrees.createScratch(
            name: "wt", displayName: "wt", path: wtDir.path, tmuxServer: "tbd-test")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "sess-1", kind: .claude)

        // Stored transcript lives under an OLD slug (as after a promote).
        let ambientRoot = home.appendingPathComponent("claude-host/projects", isDirectory: true)
        let oldSlugFile = ambientRoot.appendingPathComponent("-old-slug/sess-1.jsonl")
        try FileManager.default.createDirectory(
            at: oldSlugFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "parked transcript".write(to: oldSlugFile, atomically: true, encoding: .utf8)
        try await db.terminals.updateSession(
            id: terminal.id, sessionID: "sess-1", transcriptPath: oldSlugFile.path)
        try await db.terminals.setHibernated(id: terminal.id, sessionID: "sess-1")

        let result = await router.hibernationCoordinator.wake(terminalID: terminal.id)

        #expect(result == .ok)
        #expect(try await db.terminals.get(id: terminal.id)?.hibernatedAt == nil)
        let derived = TranscriptProjectDirSync.derivedProjectDir(
            worktreePath: wtDir.path, projectsRoot: ambientRoot)
        #expect(try String(
            contentsOf: derived.appendingPathComponent("sess-1.jsonl"), encoding: .utf8)
            == "parked transcript")
    }
}

/// Wiring test for the `terminal.create` resume path: the handler must call
/// `ensureSessionResumable` with the resumed session's STORED transcript path
/// (from the sibling terminal row that owns the session) and the worktree's
/// CURRENT path, so a wrong-argument regression can't stay green.
@Suite("terminal.create pre-resume sync wiring")
struct TerminalCreateResumeSyncWiringTests {
    private func isolate() -> (URL, () -> Void) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-create-resume-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let priorTBDHome = setTBDHome(home.path)
        let priorClaudeHost = setClaudeHostHome(home.appendingPathComponent("claude-host").path)
        return (home, {
            restoreTBDHome(priorTBDHome)
            restoreClaudeHostHome(priorClaudeHost)
            try? FileManager.default.removeItem(at: home)
        })
    }

    @Test func terminalCreateResumeSyncsStoredTranscriptIntoDerivedDir() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            configDirManager: ClaudeProfileConfigDirManager(
                baseDirectory: home.appendingPathComponent("profiles", isDirectory: true),
                hostBaseDirectory: home.appendingPathComponent("claude-host", isDirectory: true)
            )
        )

        let wtDir = home.appendingPathComponent("wt", isDirectory: true)
        try FileManager.default.createDirectory(at: wtDir, withIntermediateDirectories: true)
        let wt = try await db.worktrees.createScratch(
            name: "wt", displayName: "wt", path: wtDir.path, tmuxServer: "tbd-test")

        // Sibling terminal owns the session; its stored transcript lives under
        // an OLD slug (as after a promote/move).
        let sibling = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "sess-w", kind: .claude)
        let ambientRoot = home.appendingPathComponent("claude-host/projects", isDirectory: true)
        let oldSlugFile = ambientRoot.appendingPathComponent("-old-slug/sess-w.jsonl")
        try FileManager.default.createDirectory(
            at: oldSlugFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "moved transcript".write(to: oldSlugFile, atomically: true, encoding: .utf8)
        try await db.terminals.updateSession(
            id: sibling.id, sessionID: "sess-w", transcriptPath: oldSlugFile.path)
        ClaudeProjectDirectory.clearCache()

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, resumeSessionID: "sess-w")))
        #expect(resp.success)

        // The stored transcript was mirrored into the dir derived from the
        // worktree's CURRENT path, where the cwd-scoped resume will look.
        let derived = TranscriptProjectDirSync.derivedProjectDir(
            worktreePath: wtDir.path, projectsRoot: ambientRoot)
        #expect(try String(
            contentsOf: derived.appendingPathComponent("sess-w.jsonl"), encoding: .utf8)
            == "moved transcript")
        // Live-session invariant: the sibling's stored path was NOT rewritten.
        #expect(try await db.terminals.get(id: sibling.id)?.transcriptPath == oldSlugFile.path)
    }
}

}
