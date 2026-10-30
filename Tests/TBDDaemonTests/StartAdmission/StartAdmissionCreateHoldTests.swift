import Foundation
import DaemonTestSupport
import TestSupport
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

// Nested under TBDHomeSerialized: worktree creation resolves hooks and the
// scratch folder under TBD_HOME, so these tests redirect it to a temp dir.
extension TBDHomeSerialized {
/// Hold paths of `worktree.create` and `scratch.create`: a held create leaves
/// no row, no folder and no git state behind. The stubbed verdict is the
/// same `StubAdmission` the router tests use.
@Suite("StartAdmission create holds")
struct StartAdmissionCreateHoldTests {

    private static let holdReason = "camera in use"

    private func isolateTBDHome() -> (home: URL, cleanup: () -> Void) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-admission-create-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let prior = setTBDHome(home.path)
        return (home, {
            restoreTBDHome(prior)
            try? FileManager.default.removeItem(at: home)
        })
    }

    private struct Fixture {
        let router: RPCRouter
        let db: TBDDatabase
        let logPath: String
        let stub: StubAdmission
    }

    private func makeFixture(verdict: StartAdmissionVerdict) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-admission-create-log-\(UUID().uuidString)", isDirectory: true)
        let path = directory.appendingPathComponent("actuations.jsonl").path
        let db = try TBDDatabase(inMemory: true)
        let tmux = TmuxManager(dryRun: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux, startTime: Date(), actuationLog: ActuationLog(path: path))
        let stub = StubAdmission(verdict)
        router.startAdmission = stub
        try await db.config.setStartAdmissionEnabled(true)
        return Fixture(router: router, db: db, logPath: path, stub: stub)
    }

    private func outcome(at path: String) throws -> [String: Any] {
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        let last = try #require(contents.split(separator: "\n").last)
        return try #require(
            try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
    }

    private func directoryEntries(_ url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }

    // MARK: - worktree.create

    @Test("a held worktree.create from a session or anonymous actor leaves nothing behind",
          arguments: [ActuationActor.Kind.session, ActuationActor.Kind.anonymous])
    func heldWorktreeCreateLeavesNothing(kind: String) async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fixture = try await makeFixture(verdict: .hold(reason: Self.holdReason))
        let repo = try await makeTestRepo(db: fixture.db, tempDir: tempDir, repoDir: repoDir)
        let git = GitManager()
        let branchesBefore = try await git.listRefs(repoPath: repoDir.path, prefix: "refs/heads")
        let worktreesBefore = try await git.worktreeList(repoPath: repoDir.path).map(\.path)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.worktreeCreate,
            params: WorktreeCreateParams(repoID: repo.id),
            actor: ActuationActor(kind: kind)))

        #expect(!response.success)
        #expect(response.errorCode == RPCErrorCode.startHeld.rawValue)
        #expect(response.error == Self.holdReason)
        // The phase-1 `.creating` row is deleted.
        #expect(try await fixture.db.worktrees.list(repoID: repo.id).isEmpty)
        // No branch, no git worktree, no folder on disk.
        #expect(try await git.listRefs(repoPath: repoDir.path, prefix: "refs/heads") == branchesBefore)
        #expect(try await git.worktreeList(repoPath: repoDir.path).map(\.path) == worktreesBefore)
        #expect(directoryEntries(URL(fileURLWithPath: WorktreeLayout().basePath(for: repo))).isEmpty)
        // The actuation ended refused, with the hold's reason.
        let ended = try outcome(at: fixture.logPath)
        #expect(ended["result"] as? String == "refused")
        #expect(ended["reason"] as? String == "held")
        #expect(fixture.stub.requests.count == 1)
        #expect(fixture.stub.requests.first?.kind == .create)
    }

    @Test("the app's worktree.create is not held")
    func appWorktreeCreateIsNotHeld() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fixture = try await makeFixture(verdict: .hold(reason: Self.holdReason))
        let repo = try await makeTestRepo(db: fixture.db, tempDir: tempDir, repoDir: repoDir)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.worktreeCreate,
            params: WorktreeCreateParams(repoID: repo.id),
            actor: .app))

        #expect(response.success)
        #expect(fixture.stub.requests.isEmpty)
        let pending = try response.decodeResult(Worktree.self)
        // Phase 2 runs in the background; let it finish before the fixtures go.
        let deadline = Date().addingTimeInterval(TestDeadlines.saturatedPassSeconds)
        while Date() < deadline,
              try await fixture.db.worktrees.get(id: pending.id)?.status == .creating {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(try await fixture.db.worktrees.get(id: pending.id)?.status == .active)
    }

    // MARK: - scratch.create

    @Test("a held scratch.create removes its folder and row")
    func heldScratchCreateLeavesNothing() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let fixture = try await makeFixture(verdict: .hold(reason: Self.holdReason))

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.scratchCreate,
            params: ScratchCreateParams(name: "notes")))

        #expect(!response.success)
        #expect(response.errorCode == RPCErrorCode.startHeld.rawValue)
        #expect(response.error == Self.holdReason)
        #expect(try await fixture.db.worktrees.listScratch().isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: TBDConstants.scratchDir.appendingPathComponent("notes").path))
        #expect(directoryEntries(TBDConstants.scratchDir).isEmpty)
        let ended = try outcome(at: fixture.logPath)
        #expect(ended["result"] as? String == "refused")
        #expect(ended["reason"] as? String == "held")
        #expect(fixture.stub.requests.count == 1)
        #expect(fixture.stub.requests.first?.kind == .create)
    }

    @Test("the app's scratch.create is not held")
    func appScratchCreateIsNotHeld() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let fixture = try await makeFixture(verdict: .hold(reason: Self.holdReason))

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.scratchCreate,
            params: ScratchCreateParams(name: "notes"),
            actor: .app))

        #expect(response.success)
        #expect(fixture.stub.requests.isEmpty)
        #expect(try await fixture.db.worktrees.listScratch().count == 1)
    }
}
}
