import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct MigrationV13Tests {

    @Test func v13AddsRepoColumnsAndBackfillsSlot() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/fake-repo",
            displayName: "Fake App",
            defaultBranch: "main"
        )
        let fetched = try await db.repos.get(id: repo.id)
        #expect(fetched?.worktreeSlot == "fake-app")
        #expect(fetched?.worktreeRoot == nil)
        #expect(fetched?.status == .ok)
    }

    @Test func v13CreateDeduplicatesCollidingSlots() async throws {
        let db = try TBDDatabase(inMemory: true)
        let older = try await db.repos.create(
            path: "/tmp/a", displayName: "MyApp", defaultBranch: "main"
        )
        let newer = try await db.repos.create(
            path: "/tmp/b", displayName: "MyApp", defaultBranch: "main"
        )
        let o = try await db.repos.get(id: older.id)
        let n = try await db.repos.get(id: newer.id)
        #expect(o?.worktreeSlot == "myapp")
        #expect(n?.worktreeSlot == "myapp-2")
    }

    @Test func v13FallbackForReservedDisplayName() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/c", displayName: "...", defaultBranch: "main"
        )
        let f = try await db.repos.get(id: repo.id)
        let slot = try #require(f?.worktreeSlot)
        #expect(slot.hasPrefix("repo-"))
        #expect(slot.count == "repo-".count + 6)
    }
}
