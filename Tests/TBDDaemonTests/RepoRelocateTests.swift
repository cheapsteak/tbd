import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

@Suite struct RepoRelocateTests {

    /// A real git repo at `url`, with one empty commit on `main`.
    private func makeGitRepo(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try await initTestRepo(at: url)
    }

    private func makeRouter(db: TBDDatabase) -> RPCRouter {
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
            actuationLog: makeTestActuationLog()
        )
    }

    @Test func relocateUpdatesRepoPathAndStatus() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase-b-rel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let oldDir = tmp.appendingPathComponent("old").path
        let newDir = tmp.appendingPathComponent("new")
        try await makeGitRepo(at: newDir)

        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: oldDir, displayName: "rel", defaultBranch: "main")
        try await db.repos.updateStatus(id: repo.id, status: .missing)

        let router = makeRouter(db: db)
        let paramsData = try JSONEncoder().encode(
            RepoRelocateParams(repoID: repo.id, newPath: newDir.path)
        )
        let response = try await router.handleRepoRelocate(paramsData)
        #expect(response.success)

        let after = try await db.repos.get(id: repo.id)
        #expect(after?.path == newDir.path)
        #expect(after?.status == .ok)
    }

    @Test func relocateRejectsNonGitNewPath() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase-b-rel-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/old", displayName: "rel", defaultBranch: "main")

        let router = makeRouter(db: db)
        let paramsData = try JSONEncoder().encode(
            RepoRelocateParams(repoID: repo.id, newPath: tmp.path)
        )
        let response = try await router.handleRepoRelocate(paramsData)
        #expect(!response.success)
        #expect(response.error?.contains("Not a git repository") == true)
    }

    @Test func relocateFailsForUnknownRepoID() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db)
        let paramsData = try JSONEncoder().encode(
            RepoRelocateParams(repoID: UUID(), newPath: "/tmp/whatever")
        )
        let response = try await router.handleRepoRelocate(paramsData)
        #expect(!response.success)
        #expect(response.error?.contains("Repository not found") == true)
    }
}
