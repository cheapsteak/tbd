import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Nested under TBDHomeSerialized: `scratch.create` writes under
// `TBDConstants.scratchDir` and `worktree.create` resolves hooks under
// TBD_HOME, so these redirect it to a temp dir (see TBDHomeSerializedSuites).
extension TBDHomeSerialized {
/// Tier 2 — dry-run tmux, a real (temp-directory) actuation log, real git for
/// the `worktree.create` fixture.
///
/// The three surfaces that end in the lifecycle's own terminal spawn:
/// `worktree.create`, `scratch.create` and the merge-park rail. Each writes a
/// row naming what it is about to act on, before it acts — and refuses the act
/// when the record is unwritable.
@Suite("Actuation log spawn wiring")
struct ActuationLogSpawnWiringTests {

    // MARK: - Fixture

    private func isolateTBDHome() -> (home: URL, cleanup: () -> Void) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-actuation-spawn-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let priorTBDHome = setTBDHome(home.path)
        return (home, {
            restoreTBDHome(priorTBDHome)
            try? FileManager.default.removeItem(at: home)
        })
    }

    private func makeLogPath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-actuation-spawn-log-\(UUID().uuidString)", isDirectory: true)
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

    private func makeRouter(db: TBDDatabase, logPath: String) -> RPCRouter {
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
            actuationLog: ActuationLog(path: logPath)
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
        _ condition: @Sendable () async throws -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return try await condition()
    }

    // MARK: - scratch.create

    @Test("scratch.create writes one spawn row naming the scratch space")
    func scratchCreateWritesSpawnRow() async throws {
        let iso = isolateTBDHome(); defer { iso.cleanup() }
        let logPath = try makeLogPath()
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db, logPath: logPath)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.scratchCreate,
            params: ScratchCreateParams(name: nil),
            actor: .app))
        #expect(response.success)
        let scratch = try response.decodeResult(Worktree.self)

        let written = try rows(at: logPath)
        #expect(written.count == 2)
        let request = try #require(written.first)
        #expect(request["kind"] as? String == "spawn")
        #expect(request["method"] as? String == "scratch.create")
        let target = try #require(request["target"] as? [String: Any])
        #expect(target["worktree"] as? String == scratch.id.uuidString)
        // The terminals are minted inside the lifecycle spawn, so the row names
        // the worktree and nothing else.
        #expect(target["terminal"] == nil)
        #expect((request["actor"] as? [String: Any])?["kind"] as? String == "app")
        #expect(written.last?["result"] as? String == "dispatched")
    }

    @Test("an unwritable record refuses the scratch spawn — no terminal is created")
    func unwritableRecordRefusesScratchSpawn() async throws {
        let iso = isolateTBDHome(); defer { iso.cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db, logPath: try makeUnwritablePath())

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: nil)))

        #expect(!response.success)
        #expect(try #require(response.error).contains("actuation log"))
        // The scratch row itself is not an actuation and survives; the spawn
        // did not happen.
        let scratches = try await db.worktrees.listScratch()
        let created = try #require(scratches.first)
        #expect(try await db.terminals.list(worktreeID: created.id).isEmpty)
    }

    // MARK: - worktree.create

    @Test("worktree.create writes one spawn row naming the worktree it just minted")
    func worktreeCreateWritesSpawnRow() async throws {
        let iso = isolateTBDHome(); defer { iso.cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logPath = try makeLogPath()
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db, logPath: logPath)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeCreate,
            params: WorktreeCreateParams(repoID: repo.id),
            actor: .app))
        #expect(response.success)
        let pending = try response.decodeResult(Worktree.self)

        let written = try rows(at: logPath)
        #expect(written.count == 2)
        let request = try #require(written.first)
        #expect(request["kind"] as? String == "spawn")
        #expect(request["method"] as? String == "worktree.create")
        let target = try #require(request["target"] as? [String: Any])
        #expect(target["worktree"] as? String == pending.id.uuidString)
        #expect(target["terminal"] == nil)
        #expect((request["actor"] as? [String: Any])?["kind"] as? String == "app")
        #expect(written.last?["result"] as? String == "dispatched")

        // Let the background phase finish before the fixture repo goes away.
        _ = try await waitUntil {
            try await db.worktrees.get(id: pending.id)?.status != .creating
        }
    }

    @Test("an unwritable record refuses the create and leaves no half-created row")
    func unwritableRecordRefusesWorktreeCreate() async throws {
        let iso = isolateTBDHome(); defer { iso.cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db, logPath: try makeUnwritablePath())
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeCreate,
            params: WorktreeCreateParams(repoID: repo.id)))

        #expect(!response.success)
        #expect(try #require(response.error).contains("actuation log"))
        // The `.creating` row phase 1 inserted is swept back out, so nothing is
        // left spinning in the sidebar forever.
        let rowsForRepo = try await db.worktrees.list(repoID: repo.id, status: .creating)
        #expect(rowsForRepo.isEmpty)
    }

    // MARK: - The merge-park rail

    /// In-memory DB + repo + worktree + one idle Claude terminal.
    private func makeParkable(
        keepWarm: Bool = false
    ) async throws -> (db: TBDDatabase, worktreeID: UUID, terminalID: UUID) {
        let db = try TBDDatabase(inMemory: true)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-merge-park-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repo = try await db.repos.create(
            path: directory.path, displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme-wt", branch: "main",
            path: directory.path, tmuxServer: "tbd-acme")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-1", kind: .claude)
        try await db.terminals.setActivityState(id: terminal.id, activityState: .idle)
        if keepWarm {
            try await db.terminals.setKeepWarm(id: terminal.id, keepWarm: true)
        }
        return (db, worktree.id, terminal.id)
    }

    private func makeCoordinator(
        db: TBDDatabase, logPath: String
    ) -> HibernationCoordinator {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-merge-park-claude-\(UUID().uuidString)", isDirectory: true)
        return HibernationCoordinator(
            db: db,
            tmux: TmuxManager(dryRun: true),
            configDirManager: ClaudeProfileConfigDirManager(
                baseDirectory: home.appendingPathComponent("profiles", isDirectory: true),
                hostBaseDirectory: home.appendingPathComponent("claude-host", isDirectory: true)),
            actuationLog: ActuationLog(path: logPath))
    }

    @Test("merge-park writes its own rail row, with no method and a rail-named actor")
    func mergeParkWritesRailRow() async throws {
        let fixture = try await makeParkable()
        let logPath = try makeLogPath()
        let coordinator = makeCoordinator(db: fixture.db, logPath: logPath)

        let result = await coordinator.hibernateForMerge(terminalID: fixture.terminalID)
        #expect(result == .ok)

        let written = try rows(at: logPath)
        #expect(written.count == 2)
        let request = try #require(written.first)
        #expect(request["kind"] as? String == "hibernate")
        // Daemon-internal: no RPC carried this, so no method.
        #expect(request["method"] == nil)
        let actor = try #require(request["actor"] as? [String: Any])
        #expect(actor["kind"] as? String == "daemon")
        #expect(actor["rail"] as? String == "auto-hibernate-on-merge")
        let target = try #require(request["target"] as? [String: Any])
        #expect(target["worktree"] as? String == fixture.worktreeID.uuidString)
        #expect(target["terminal"] as? String == fixture.terminalID.uuidString)
        #expect(written.last?["result"] as? String == "dispatched")
    }

    @Test("a terminal the rails refuse is never acted on, so it writes no row")
    func mergeParkRefusedByRailWritesNothing() async throws {
        let fixture = try await makeParkable(keepWarm: true)
        let logPath = try makeLogPath()
        let coordinator = makeCoordinator(db: fixture.db, logPath: logPath)

        let result = await coordinator.hibernateForMerge(terminalID: fixture.terminalID)
        #expect(result == .notEligible(reason: "Terminal is pinned keep-warm"))
        #expect(try rows(at: logPath).isEmpty)
    }

    @Test("an unwritable record skips the merge park — the session stays live")
    func unwritableRecordSkipsMergePark() async throws {
        let fixture = try await makeParkable()
        let coordinator = makeCoordinator(db: fixture.db, logPath: try makeUnwritablePath())

        let result = await coordinator.hibernateForMerge(terminalID: fixture.terminalID)
        guard case .notEligible(let reason) = result else {
            Issue.record("expected the park to be skipped, got \(result)")
            return
        }
        #expect(reason.contains("actuation log"))
        let after = try await fixture.db.terminals.get(id: fixture.terminalID)
        #expect(after?.hibernatedAt == nil)
    }
}
}
