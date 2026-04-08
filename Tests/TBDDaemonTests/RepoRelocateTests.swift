import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct RepoRelocateTests {

    private func makeGitRepo(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["commit", "--allow-empty", "-m", "init"]] {
            let p = Process()
            p.launchPath = "/usr/bin/env"
            p.arguments = ["git", "-C", url.path] + args
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
        }
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
            startTime: Date()
        )
    }

    @Test func relocateUpdatesRepoPathAndStatus() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase-b-rel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let oldDir = tmp.appendingPathComponent("old").path
        let newDir = tmp.appendingPathComponent("new")
        try makeGitRepo(at: newDir)

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
