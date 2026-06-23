import Testing
import Foundation
import TBDShared
@testable import TBDDaemonLib

@Suite struct AutoArchiveStoreTests {

    @Test func worktreeAutoArchiveRoundTrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/repoA", displayName: "repoA", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", displayName: "w", branch: "b",
            path: "/tmp/repoA/w", tmuxServer: "s", status: .active)
        #expect(wt.autoArchiveOnMerge == nil)

        try await db.worktrees.setAutoArchiveOnMerge(id: wt.id, value: true)
        let on = try await db.worktrees.get(id: wt.id)
        #expect(on?.autoArchiveOnMerge == true)

        try await db.worktrees.setAutoArchiveOnMerge(id: wt.id, value: false)
        let off = try await db.worktrees.get(id: wt.id)
        #expect(off?.autoArchiveOnMerge == false)
    }

    @Test func configDefaultPersistsAndDefaultsFalse() async throws {
        let db = try TBDDatabase(inMemory: true)
        let initial = try await db.config.get()
        #expect(initial.autoArchiveOnMergeDefault == false)
        try await db.config.setAutoArchiveOnMergeDefault(true)
        let updated = try await db.config.get()
        #expect(updated.autoArchiveOnMergeDefault == true)
    }
}
