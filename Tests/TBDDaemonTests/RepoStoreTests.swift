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
}
