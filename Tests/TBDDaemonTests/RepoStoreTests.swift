import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct RepoStoreUpdateTests {

    @Test func repoStoreUpdatesStatus() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/x", displayName: "x", defaultBranch: "main"
        )
        try await db.repos.updateStatus(id: repo.id, status: .missing)
        let fetched = try await db.repos.get(id: repo.id)
        #expect(fetched?.status == .missing)
        try await db.repos.updateStatus(id: repo.id, status: .ok)
        let after = try await db.repos.get(id: repo.id)
        #expect(after?.status == .ok)
    }

    @Test func repoStoreUpdatesPath() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/old", displayName: "x", defaultBranch: "main"
        )
        try await db.repos.updatePath(id: repo.id, path: "/tmp/new")
        let fetched = try await db.repos.get(id: repo.id)
        #expect(fetched?.path == "/tmp/new")
    }

    @Test func repoStoreRenamesDisplayName() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/r-\(UUID())", displayName: "old", defaultBranch: "main"
        )
        try await db.repos.rename(id: repo.id, displayName: "✨ new")
        let fetched = try await db.repos.get(id: repo.id)
        #expect(fetched?.displayName == "✨ new")
    }

    @Test func repoStoreRenameThrowsForUnknownID() async throws {
        let db = try TBDDatabase(inMemory: true)
        await #expect(throws: Error.self) {
            try await db.repos.rename(id: UUID(), displayName: "anything")
        }
    }

    // MARK: - Expand/collapse persistence

    @Test func repoStoreDefaultExpandedIsTrue() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/r-\(UUID())", displayName: "x", defaultBranch: "main"
        )
        // Newly created repos must start expanded so worktree rows are visible.
        #expect(repo.expanded == true)
        let fetched = try await db.repos.get(id: repo.id)
        #expect(fetched?.expanded == true)
    }

    @Test func repoStoreCollapsedRoundTrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/r-\(UUID())", displayName: "x", defaultBranch: "main"
        )
        try await db.repos.setExpanded(id: repo.id, expanded: false)
        let collapsed = try await db.repos.get(id: repo.id)
        #expect(collapsed?.expanded == false)

        try await db.repos.setExpanded(id: repo.id, expanded: true)
        let expanded = try await db.repos.get(id: repo.id)
        #expect(expanded?.expanded == true)
    }
}
