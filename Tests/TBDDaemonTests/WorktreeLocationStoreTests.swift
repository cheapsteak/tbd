import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct WorktreeLocationStoreTests {

    private func makeDB() throws -> TBDDatabase { try TBDDatabase(inMemory: true) }

    @Test func existingRowsMigrateToLocal() async throws {
        let db = try makeDB()
        let repo = try await db.repos.create(
            path: "/tmp/r-\(UUID().uuidString)", displayName: "r", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/r/w-\(UUID().uuidString)", tmuxServer: "s")
        let fetched = try #require(try await db.worktrees.get(id: wt.id))
        #expect(fetched.location == .local)
    }

    @Test func remoteLocationRoundTripsThroughTheStore() async throws {
        let db = try makeDB()
        let repo = try await db.repos.create(
            path: "/tmp/r-\(UUID().uuidString)", displayName: "r", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b", path: "", tmuxServer: "",
            location: .remote(provider: "agentbox", sessionID: "s-1"))
        let fetched = try #require(try await db.worktrees.get(id: wt.id))
        #expect(fetched.location == .remote(provider: "agentbox", sessionID: "s-1"))
    }
}
