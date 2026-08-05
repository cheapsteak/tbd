import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 — dry-run tmux plus a real (temp-directory) actuation log.
///
/// The teardown surfaces: `worktree.archive`, `worktree.forget`,
/// `scratch.delete` and `scratch.archive` all kill a worktree's windows, and
/// `worktree.rerunPreSession` spawns one. Each writes ONE row naming the
/// worktree — the per-terminal kills inside the lifecycle are sub-steps of the
/// one thing the caller asked for — and each refuses its act when the record is
/// unwritable.
///
/// Also here, because they are about *when* a row is written rather than which:
/// `terminal.delete`'s failed kill reads as transport-failed rather than
/// dispatched, and `terminal.swapProfile`'s row precedes the transcript copy it
/// makes on the resume path.
@Suite("Actuation log teardown wiring")
struct ActuationLogTeardownWiringTests {

    // MARK: - Fixture

    private func makeLogPath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-actuation-teardown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("actuations.jsonl").path
    }

    /// A path that can never be opened: its parent is a regular file.
    private func makeUnwritablePath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-actuation-blocked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        return blocker.appendingPathComponent("actuations.jsonl").path
    }

    private func rows(at path: String) throws -> [[String: Any]] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return try contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try #require(
                    try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
    }

    private func makeRouter(
        db: TBDDatabase, logPath: String, tmux: TmuxManager = TmuxManager(dryRun: true)
    ) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date(),
            actuationLog: ActuationLog(path: logPath))
    }

    /// A repo-backed worktree with `count` live terminals on it.
    private func makeWorktree(
        in db: TBDDatabase, terminals count: Int = 2
    ) async throws -> Worktree {
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme-wt", branch: "acme-branch",
            path: "/tmp/acme-wt-\(UUID().uuidString)", tmuxServer: "tbd-acme")
        for index in 0..<count {
            _ = try await db.terminals.create(
                worktreeID: worktree.id, tmuxWindowID: "@\(index)", tmuxPaneID: "%\(index)")
        }
        return worktree
    }

    private func makeScratch(
        in db: TBDDatabase, terminals count: Int = 2
    ) async throws -> Worktree {
        let name = "acme-scratch-\(UUID().uuidString)"
        let scratch = try await db.worktrees.createScratch(
            name: name, displayName: name, path: "/tmp/\(name)", tmuxServer: "tbd-scratch")
        for index in 0..<count {
            _ = try await db.terminals.create(
                worktreeID: scratch.id, tmuxWindowID: "@\(index)", tmuxPaneID: "%\(index)")
        }
        return scratch
    }

    // MARK: - worktree.archive

    @Test("worktree.archive writes one dispose row naming the worktree, not its terminals")
    func archiveWritesOneWorktreeNamedRow() async throws {
        let logPath = try makeLogPath()
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db, logPath: logPath)
        let worktree = try await makeWorktree(in: db)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeArchive,
            params: WorktreeArchiveParams(worktreeID: worktree.id),
            actor: .app))
        #expect(response.success)

        let written = try rows(at: logPath)
        // Two terminals died, but the caller asked for one thing — so one row.
        #expect(written.count == 2)
        let request = try #require(written.first)
        #expect(request["kind"] as? String == "dispose")
        #expect(request["method"] as? String == "worktree.archive")
        let target = try #require(request["target"] as? [String: Any])
        #expect(target["worktree"] as? String == worktree.id.uuidString)
        #expect(target["terminal"] == nil)
        #expect((request["actor"] as? [String: Any])?["kind"] as? String == "app")

        let outcome = try #require(written.last)
        #expect(outcome["confirms"] as? String == request["id"] as? String)
        #expect(outcome["result"] as? String == "dispatched")
        #expect(try await db.terminals.list(worktreeID: worktree.id).isEmpty)
    }

    @Test("an unwritable record refuses the archive — the sessions stay live")
    func unwritableRecordRefusesArchive() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db, logPath: try makeUnwritablePath())
        let worktree = try await makeWorktree(in: db)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeArchive,
            params: WorktreeArchiveParams(worktreeID: worktree.id)))

        #expect(!response.success)
        #expect(try #require(response.error).contains("actuation log"))
        #expect(try await db.worktrees.get(id: worktree.id)?.status == .active)
        #expect(try await db.terminals.list(worktreeID: worktree.id).count == 2)
    }

    // MARK: - worktree.forget

    @Test("worktree.forget writes one dispose row under its own method")
    func forgetWritesOneWorktreeNamedRow() async throws {
        let logPath = try makeLogPath()
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db, logPath: logPath)
        let worktree = try await makeWorktree(in: db)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeForget,
            params: WorktreeForgetParams(worktreeID: worktree.id),
            actor: .app))
        #expect(response.success)

        let written = try rows(at: logPath)
        #expect(written.count == 2)
        let request = try #require(written.first)
        #expect(request["kind"] as? String == "dispose")
        #expect(request["method"] as? String == "worktree.forget")
        let target = try #require(request["target"] as? [String: Any])
        #expect(target["worktree"] as? String == worktree.id.uuidString)
        #expect(target["terminal"] == nil)
        #expect(written.last?["result"] as? String == "dispatched")
        #expect(try await db.worktrees.get(id: worktree.id) == nil)
    }

    @Test("an unwritable record refuses the forget — the row and its sessions survive")
    func unwritableRecordRefusesForget() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db, logPath: try makeUnwritablePath())
        let worktree = try await makeWorktree(in: db)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeForget,
            params: WorktreeForgetParams(worktreeID: worktree.id)))

        #expect(!response.success)
        #expect(try #require(response.error).contains("actuation log"))
        #expect(try await db.worktrees.get(id: worktree.id) != nil)
        #expect(try await db.terminals.list(worktreeID: worktree.id).count == 2)
    }

    // MARK: - worktree.rerunPreSession

    @Test("a pre-session re-run with no hook writes a spawn row confirmed as refused")
    func rerunPreSessionRefusalIsRecorded() async throws {
        let logPath = try makeLogPath()
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db, logPath: logPath)
        let worktree = try await makeWorktree(in: db, terminals: 0)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeRerunPreSession,
            params: WorktreeRerunPreSessionParams(worktreeID: worktree.id),
            actor: .app))
        #expect(!response.success)

        let written = try rows(at: logPath)
        #expect(written.count == 2)
        let request = try #require(written.first)
        #expect(request["kind"] as? String == "spawn")
        #expect(request["method"] as? String == "worktree.rerunPreSession")
        let target = try #require(request["target"] as? [String: Any])
        #expect(target["worktree"] as? String == worktree.id.uuidString)
        // The hook's terminal is minted inside the lifecycle, so there is none
        // to name at request time.
        #expect(target["terminal"] == nil)

        let outcome = try #require(written.last)
        #expect(outcome["confirms"] as? String == request["id"] as? String)
        #expect(outcome["result"] as? String == "refused")
        #expect(outcome["reason"] as? String == "not-eligible")
        #expect(outcome["error"] as? String == response.error)
    }

    @Test("a pre-session re-run on a vanished worktree is refused as not-found")
    func rerunPreSessionMissingWorktreeIsNotFound() async throws {
        let logPath = try makeLogPath()
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db, logPath: logPath)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeRerunPreSession,
            params: WorktreeRerunPreSessionParams(worktreeID: UUID())))
        #expect(!response.success)

        let written = try rows(at: logPath)
        #expect(written.count == 2)
        #expect(written.last?["result"] as? String == "refused")
        #expect(written.last?["reason"] as? String == "not-found")
    }

    // MARK: - scratch.delete / scratch.archive

    @Test("scratch.delete writes one dispose row naming the scratch space")
    func scratchDeleteWritesOneRow() async throws {
        let logPath = try makeLogPath()
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db, logPath: logPath)
        let scratch = try await makeScratch(in: db)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.scratchDelete,
            params: ScratchDeleteParams(worktreeID: scratch.id),
            actor: .app))
        #expect(response.success)

        let written = try rows(at: logPath)
        #expect(written.count == 2)
        let request = try #require(written.first)
        #expect(request["kind"] as? String == "dispose")
        #expect(request["method"] as? String == "scratch.delete")
        let target = try #require(request["target"] as? [String: Any])
        #expect(target["worktree"] as? String == scratch.id.uuidString)
        #expect(target["terminal"] == nil)
        #expect(written.last?["result"] as? String == "dispatched")
        #expect(try await db.worktrees.get(id: scratch.id) == nil)
    }

    @Test("scratch.archive writes the same dispose row under its own method")
    func scratchArchiveWritesOneRow() async throws {
        let logPath = try makeLogPath()
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db, logPath: logPath)
        let scratch = try await makeScratch(in: db)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.scratchArchive,
            params: ScratchArchiveParams(worktreeID: scratch.id),
            actor: .app))
        #expect(response.success)

        let written = try rows(at: logPath)
        #expect(written.count == 2)
        #expect(written.first?["kind"] as? String == "dispose")
        #expect(written.first?["method"] as? String == "scratch.archive")
        #expect(written.last?["result"] as? String == "dispatched")
        #expect(try await db.worktrees.get(id: scratch.id)?.status == .archived)
    }

    @Test("a scratch space that does not exist is declined before any row exists")
    func scratchDeleteOfAbsentRowWritesNothing() async throws {
        let logPath = try makeLogPath()
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db, logPath: logPath)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.scratchDelete, params: ScratchDeleteParams(worktreeID: UUID())))
        #expect(!response.success)
        #expect(try rows(at: logPath).isEmpty)
    }

    @Test("an unwritable record refuses the scratch teardown — the sessions stay live")
    func unwritableRecordRefusesScratchTeardown() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db, logPath: try makeUnwritablePath())
        let scratch = try await makeScratch(in: db)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.scratchDelete,
            params: ScratchDeleteParams(worktreeID: scratch.id)))

        #expect(!response.success)
        #expect(try #require(response.error).contains("actuation log"))
        #expect(try await db.worktrees.get(id: scratch.id) != nil)
        #expect(try await db.terminals.list(worktreeID: scratch.id).count == 2)
    }

    // MARK: - terminal.delete: a kill that failed is not a dispatch

    @Test("terminal.delete records a failed kill as transport-failed, and still closes")
    func deleteRecordsFailedKillAsTransportFailed() async throws {
        struct TmuxWentAway: Error, CustomStringConvertible {
            var description: String { "no server running on tbd-acme" }
        }
        let logPath = try makeLogPath()
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(
            db: db, logPath: logPath,
            tmux: TmuxManager(dryRun: true, dryRunKillWindowError: { _, _ in TmuxWentAway() }))
        let worktree = try await makeWorktree(in: db, terminals: 0)
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1")

        // The UX is unchanged: the deletion proceeds and the response is the
        // same one a clean kill returns.
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: terminal.id),
            actor: .app))
        #expect(response.success)
        #expect(try response.decodeResult(TerminalDeleteResult.self).closed)
        #expect(try await db.terminals.get(id: terminal.id) == nil)

        // Only the record knows the kill failed — which is the point.
        let written = try rows(at: logPath)
        #expect(written.count == 2)
        #expect(written.first?["kind"] as? String == "dispose")
        let outcome = try #require(written.last)
        #expect(outcome["result"] as? String == "transport-failed")
        #expect(outcome["error"] as? String == "\(TmuxWentAway())")
        #expect(outcome["reason"] == nil)
    }

    @Test("a clean kill still reads as dispatched")
    func deleteWithLiveTmuxStaysDispatched() async throws {
        let logPath = try makeLogPath()
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db, logPath: logPath)
        let worktree = try await makeWorktree(in: db, terminals: 0)
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1")

        _ = await router.handle(try RPCRequest(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: terminal.id)))

        #expect(try rows(at: logPath).last?["result"] as? String == "dispatched")
    }

    // MARK: - terminal.swapProfile: the row precedes the transcript copy

    /// The resume branch copies the session transcript into the DESTINATION
    /// profile's config dir before it respawns anything — a real mutation
    /// outside the daemon. So the row has to come first, and the way to prove it
    /// is to make the record unwritable: the copy must not have happened either.
    @Test("an unwritable record refuses the swap before it copies the transcript")
    func unwritableRecordRefusesSwapBeforeTranscriptCarry() async throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-swap-row-base-\(UUID().uuidString)", isDirectory: true)
        let hostDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-swap-row-host-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: baseDir)
            try? FileManager.default.removeItem(at: hostDir)
        }
        let manager = ClaudeProfileConfigDirManager(
            baseDirectory: baseDir, hostBaseDirectory: hostDir)

        let db = try TBDDatabase(inMemory: true)
        let tmux = TmuxManager(dryRun: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date(),
            usageFetcher: StubClaudeUsageFetcher(),
            configDirManager: manager,
            actuationLog: ActuationLog(path: try makeUnwritablePath()))

        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme-wt", branch: "main",
            path: "/tmp/acme-wt-\(UUID().uuidString)", tmuxServer: "tbd-acme")
        let destination = try await db.modelProfiles.create(name: "Dest", kind: .oauth)
        defer { try? ModelProfileKeychain.delete(id: destination.id.uuidString) }

        // An ambient Claude session with a non-blank transcript under the host
        // (ambient) config dir — the shape whose swap carries a transcript.
        let sessionID = UUID().uuidString
        let slug = "-acme-slug"
        let projectDir = hostDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let transcript = projectDir.appendingPathComponent("\(sessionID).jsonl")
        try #"{"type":"user","message":{"role":"user","content":"hello there"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)

        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, claudeSessionID: sessionID, kind: .claude)
        try await db.terminals.updateSession(
            id: terminal.id, sessionID: sessionID, transcriptPath: transcript.path)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminal.id, newProfileID: destination.id)))

        #expect(!response.success)
        #expect(try #require(response.error).contains("actuation log"))
        // Nothing was carried into the destination profile: the refusal landed
        // ahead of the copy, which is what the row's placement buys.
        let carried = manager.configDirectory(forProfileID: destination.id)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        #expect(!FileManager.default.fileExists(atPath: carried.path))
        // And the session was left exactly as it was.
        #expect(try await db.terminals.get(id: terminal.id)?.profileID == nil)
    }
}
