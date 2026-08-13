import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 — in-memory database, dry-run tmux, a real actuation log in a temp
/// directory. No `TBD_HOME`, no subprocesses.
///
/// `worktree.archive` refuses a remote lane before it writes its `.dispose`
/// request. A remote worktree cannot be archived today — `beginArchiveWorktree`
/// resolves through `getLocal` and throws for one — so a request row for it
/// would claim an act that was never attempted. Unlike the auto-archive rail's
/// silent skip, this path is a deliberate user gesture, so the refusal comes
/// back as an RPC error the caller can show.
///
/// Both arms are here: the refusal, and a local worktree archiving exactly as
/// before, which is what proves the fence did not disarm the surface.
@Suite("worktree.archive: remote lanes")
struct WorktreeArchiveRemoteLaneTests {

    // MARK: - Fixture

    private func makeLogPath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-archive-remote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("actuations.jsonl").path
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

    private func makeRouter(db: TBDDatabase, logPath: String) -> RPCRouter {
        let tmux = TmuxManager(dryRun: true)
        return RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date(),
            actuationLog: ActuationLog(path: logPath))
    }

    private func makeRepo(in db: TBDDatabase) async throws -> Repo {
        try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
    }

    // MARK: - Tests

    @Test("archiving a remote lane is refused, and writes no actuation row for it")
    func remoteLaneIsRefusedAndRecordsNothing() async throws {
        let logPath = try makeLogPath()
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db, logPath: logPath)
        let repo = try await makeRepo(in: db)
        let worktree = try await db.worktrees.createRemote(
            repoID: repo.id, name: "acme-remote", branch: "acme-branch",
            provider: "acme-provider", sessionID: "sess-1")

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeArchive,
            params: WorktreeArchiveParams(worktreeID: worktree.id),
            actor: .app))

        #expect(!response.success)
        #expect(response.error?.contains("remote lane") == true,
                "the refusal did not say why: \(response.error ?? "no error")")
        #expect(try await db.worktrees.get(id: worktree.id)?.status == .active)
        // Not "no dispose row" but no row of any kind: the handler never
        // reached its act moment, so it has nothing to record — neither a
        // request nor the transport-failed outcome the downstream throw used to
        // produce.
        #expect(try rows(at: logPath).isEmpty)
    }

    /// The CLI's `--force` reaches the same handler, and force is about phase 2
    /// (skipping the dirty-tree check on `git worktree remove`), not about
    /// locality — there is still no provider session teardown to run.
    @Test("a forced archive of a remote lane is refused the same way")
    func forcedRemoteLaneIsAlsoRefused() async throws {
        let logPath = try makeLogPath()
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db, logPath: logPath)
        let repo = try await makeRepo(in: db)
        let worktree = try await db.worktrees.createRemote(
            repoID: repo.id, name: "acme-remote", branch: "acme-branch",
            provider: "acme-provider", sessionID: "sess-1")

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeArchive,
            params: WorktreeArchiveParams(worktreeID: worktree.id, force: true),
            actor: .app))

        #expect(!response.success)
        #expect(try await db.worktrees.get(id: worktree.id)?.status == .active)
        #expect(try rows(at: logPath).isEmpty)
    }

    @Test("a local worktree still archives and records its act")
    func localWorktreeStillArchives() async throws {
        let logPath = try makeLogPath()
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db, logPath: logPath)
        let repo = try await makeRepo(in: db)
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme-local", branch: "acme-branch",
            path: "/tmp/acme-wt-\(UUID().uuidString)", tmuxServer: "tbd-acme")

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeArchive,
            params: WorktreeArchiveParams(worktreeID: worktree.id),
            actor: .app))

        #expect(response.success, "the archive was refused: \(response.error ?? "no error")")
        #expect(try await db.worktrees.get(id: worktree.id)?.status == .archived)
        let written = try rows(at: logPath)
        #expect(written.count == 2)
        #expect(written.first?["kind"] as? String == "dispose")
        #expect(written.first?["method"] as? String == RPCMethod.worktreeArchive)
        #expect(written.last?["result"] as? String == "dispatched")
    }

    /// The pre-row read must not swallow the not-found case: an unknown id still
    /// reaches `beginArchiveWorktree` and still records a transport-failed
    /// outcome, exactly as it did before the fence.
    @Test("an unknown worktree id still throws and records transport-failed")
    func unknownWorktreeStillRecordsTransportFailure() async throws {
        let logPath = try makeLogPath()
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db, logPath: logPath)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeArchive,
            params: WorktreeArchiveParams(worktreeID: UUID()),
            actor: .app))

        #expect(!response.success)
        let written = try rows(at: logPath)
        #expect(written.count == 2)
        #expect(written.first?["kind"] as? String == "dispose")
        #expect(written.last?["result"] as? String == "transport-failed")
    }
}
