import Testing
import Foundation
import TBDShared
@testable import TBDDaemonLib

@Suite struct AutoHibernateStoreTests {

    @Test func worktreeAutoHibernateRoundTrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/repoA", displayName: "repoA", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", displayName: "w", branch: "b",
            path: "/tmp/repoA/w", tmuxServer: "s", status: .active)
        #expect(wt.autoHibernateOnMerge == nil)

        try await db.worktrees.setAutoHibernateOnMerge(id: wt.id, value: true)
        let on = try await db.worktrees.get(id: wt.id)
        #expect(on?.autoHibernateOnMerge == true)

        try await db.worktrees.setAutoHibernateOnMerge(id: wt.id, value: false)
        let off = try await db.worktrees.get(id: wt.id)
        #expect(off?.autoHibernateOnMerge == false)

        try await db.worktrees.setAutoHibernateOnMerge(id: wt.id, value: nil)
        let cleared = try await db.worktrees.get(id: wt.id)
        #expect(cleared?.autoHibernateOnMerge == nil)
    }

    @Test func configDefaultPersistsAndDefaultsFalse() async throws {
        let db = try TBDDatabase(inMemory: true)
        let initial = try await db.config.get()
        #expect(initial.autoHibernateOnMergeDefault == false)
        try await db.config.setAutoHibernateOnMergeDefault(true)
        let updated = try await db.config.get()
        #expect(updated.autoHibernateOnMergeDefault == true)
    }
}
