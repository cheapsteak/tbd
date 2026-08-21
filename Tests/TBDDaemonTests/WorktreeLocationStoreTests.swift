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

    /// A landed row: `location` says the files are here, the two provider
    /// columns say which session it came from. Today the record erases that in
    /// both directions — `init(from:)` nils both columns for the `.local` case
    /// and `toModel()` discards them unless the kind is `"remote"`.
    @Test func landedRowRoundTripsThroughTheRecord() throws {
        let landed = Worktree(
            repoID: UUID(), name: "w", displayName: "w", branch: "b",
            path: "/tmp/landed", tmuxServer: "srv",
            location: .local,
            origin: WorktreeOrigin(provider: "claude-cloud", sessionID: "session_01AAAA"))
        let round = try #require(WorktreeRecord(from: landed).toModel())
        #expect(round.location == .local)
        #expect(round.origin == WorktreeOrigin(provider: "claude-cloud", sessionID: "session_01AAAA"))
        #expect(round.localPath == "/tmp/landed")
    }

    /// Adoption's idempotence check must keep matching after a landing, or the
    /// next complete snapshot mints a second row for a session that already has
    /// a lane on this machine.
    @Test func findRemoteStillMatchesALandedRow() async throws {
        let db = try makeDB()
        let repo = try await db.repos.create(
            path: "/tmp/r-\(UUID().uuidString)", displayName: "r", defaultBranch: "main")
        let remote = try await db.worktrees.createRemote(
            repoID: repo.id, name: "w", branch: "b",
            provider: "claude-cloud", sessionID: "session_01BBBB")

        // Land it: the files arrive on this machine, the provenance stays.
        try await db.writerForTests.write { conn in
            try conn.execute(
                sql: "UPDATE worktree SET location = 'local', path = ? WHERE id = ?",
                arguments: ["/tmp/landed-\(remote.id.uuidString)", remote.id.uuidString])
        }

        let fetched = try #require(try await db.worktrees.get(id: remote.id))
        #expect(fetched.location == .local)
        #expect(fetched.origin == WorktreeOrigin(provider: "claude-cloud", sessionID: "session_01BBBB"))

        let found = try #require(
            try await db.worktrees.findRemote(provider: "claude-cloud", sessionID: "session_01BBBB"))
        #expect(found.id == remote.id)
    }

    /// A row that never had a provider session reads back with no origin at
    /// all — nil is a real third answer, not an empty pair.
    @Test func plainLocalRowHasNoOrigin() async throws {
        let db = try makeDB()
        let repo = try await db.repos.create(
            path: "/tmp/r-\(UUID().uuidString)", displayName: "r", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/r/w-\(UUID().uuidString)", tmuxServer: "s")
        let fetched = try #require(try await db.worktrees.get(id: wt.id))
        #expect(fetched.origin == nil)
        #expect(fetched.location == .local)
    }
}
