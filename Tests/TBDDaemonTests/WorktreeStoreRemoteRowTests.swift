import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

/// `worktree.path` is `NOT NULL UNIQUE`, so remote rows — which have no
/// filesystem path — cannot all store the same placeholder. `create` derives a
/// synthetic `remote://<provider>/<sessionID>` path from the location instead,
/// which is unique per session and visibly not a filesystem path.
@Suite struct WorktreeStoreRemoteRowTests {

    private func makeDB() throws -> TBDDatabase { try TBDDatabase(inMemory: true) }

    private func makeRepo(_ db: TBDDatabase) async throws -> Repo {
        try await db.repos.create(
            path: "/tmp/r-\(UUID().uuidString)", displayName: "r", defaultBranch: "main")
    }

    /// The headline case for the follow-up PR: an orchestrator fans out to two
    /// remote lanes in one repo. Both rows must persist.
    @Test func twoRemoteRowsCoexistInOneRepo() async throws {
        let db = try makeDB()
        let repo = try await makeRepo(db)

        let first = try await db.worktrees.createRemote(
            repoID: repo.id, name: "remote-1", branch: "b1",
            provider: "agentbox", sessionID: "s-1")
        let second = try await db.worktrees.createRemote(
            repoID: repo.id, name: "remote-2", branch: "b2",
            provider: "agentbox", sessionID: "s-2")

        let rows = try await db.worktrees.list(repoID: repo.id)
        #expect(Set(rows.map(\.id)) == Set([first.id, second.id]))
        #expect(first.localPath != second.localPath)
    }

    /// The stored path is the location's synthetic URI, both in the returned
    /// value and on the row that comes back out of the database.
    @Test func remoteRowStoresTheSyntheticPath() async throws {
        let db = try makeDB()
        let repo = try await makeRepo(db)

        let created = try await db.worktrees.createRemote(
            repoID: repo.id, name: "remote", branch: "b",
            provider: "agentbox", sessionID: "s-1")

        #expect(created.localPath == "remote://agentbox/s-1")
        let fetched = try #require(try await db.worktrees.get(id: created.id))
        #expect(fetched.localPath == "remote://agentbox/s-1")
        #expect(fetched.tmuxServer == "")
    }

    /// Two sessions whose IDs differ only in a delimiter must not collapse
    /// onto one path. Percent-encoding each component is what keeps the
    /// mapping injective, so the UNIQUE constraint stays a real guard rather
    /// than an accident of which characters providers happen to use.
    @Test func sessionIDsContainingDelimitersStayDistinct() async throws {
        let db = try makeDB()
        let repo = try await makeRepo(db)

        let slashed = try await db.worktrees.createRemote(
            repoID: repo.id, name: "a", branch: "b1",
            provider: "agentbox", sessionID: "team/one")
        let flattened = try await db.worktrees.createRemote(
            repoID: repo.id, name: "b", branch: "b2",
            provider: "agentbox/team", sessionID: "one")

        #expect(slashed.localPath == "remote://agentbox/team%2Fone")
        #expect(flattened.localPath == "remote://agentbox%2Fteam/one")
        #expect(try await db.worktrees.list(repoID: repo.id).count == 2)
    }

    /// `create` derives the path from the location, so a caller that passes a
    /// real-looking path for a remote row does not get it stored.
    @Test func createIgnoresACallerSuppliedPathForARemoteRow() async throws {
        let db = try makeDB()
        let repo = try await makeRepo(db)

        let created = try await db.worktrees.create(
            repoID: repo.id, name: "remote", branch: "b",
            path: "/tmp/not-a-remote-path", tmuxServer: "",
            location: .remote(provider: "agentbox", sessionID: "s-9"))

        #expect(created.localPath == "remote://agentbox/s-9")
    }

    /// A synthetic path is still not a local checkout: local-only fetches must
    /// keep refusing the row.
    @Test func aSyntheticPathDoesNotMakeARowLocal() async throws {
        let db = try makeDB()
        let repo = try await makeRepo(db)

        let created = try await db.worktrees.createRemote(
            repoID: repo.id, name: "remote", branch: "b",
            provider: "agentbox", sessionID: "s-1")

        #expect(try await db.worktrees.getLocal(id: created.id) == nil)
        #expect(LocalWorktree(created) == nil)
    }
}
