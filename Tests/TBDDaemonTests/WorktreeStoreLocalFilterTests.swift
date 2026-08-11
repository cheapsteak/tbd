import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct WorktreeStoreLocalFilterTests {

    private func makeDB() throws -> TBDDatabase { try TBDDatabase(inMemory: true) }

    private func seed(_ db: TBDDatabase) async throws -> (repo: Repo, local: Worktree, remote: Worktree) {
        let repo = try await db.repos.create(
            path: "/tmp/r-\(UUID().uuidString)", displayName: "r", defaultBranch: "main")
        let local = try await db.worktrees.create(
            repoID: repo.id, name: "local", branch: "b1",
            path: "/tmp/r/local-\(UUID().uuidString)", tmuxServer: "srv")
        let remote = try await db.worktrees.createRemote(
            repoID: repo.id, name: "remote", branch: "b2",
            provider: "agentbox", sessionID: "s-1")
        return (repo, local, remote)
    }

    @Test func getLocalReturnsALocalRow() async throws {
        let db = try makeDB()
        let (_, local, _) = try await seed(db)
        let fetched = try await db.worktrees.getLocal(id: local.id)
        #expect(fetched?.id == local.id)
    }

    @Test func getLocalRefusesARemoteRow() async throws {
        let db = try makeDB()
        let (_, _, remote) = try await seed(db)
        #expect(try await db.worktrees.getLocal(id: remote.id) == nil)
        // The location-neutral fetch still sees it — the row is not hidden,
        // only withheld from local-only callers.
        #expect(try await db.worktrees.get(id: remote.id) != nil)
    }

    @Test func listLocalExcludesRemoteRows() async throws {
        let db = try makeDB()
        let (repo, local, _) = try await seed(db)
        let locals = try await db.worktrees.listLocal(repoID: repo.id)
        #expect(locals.map(\.id) == [local.id])
        #expect(try await db.worktrees.list(repoID: repo.id).count == 2)
    }
}
