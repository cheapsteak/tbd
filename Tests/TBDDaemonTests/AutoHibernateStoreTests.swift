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

    @Test func setAutoHibernateAcceptsTwentyFourHours() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 1440)
        let config = try await db.config.get()
        #expect(config.autoHibernateEnabled == true)
        #expect(config.hibernateIdleMinutes == 1440)
    }

    @Test func setAutoHibernateCeilingsAboveNinetyNineDays() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 200_000)
        let config = try await db.config.get()
        #expect(config.hibernateIdleMinutes == Config.maxHibernateIdleMinutes)
    }

    @Test func setAutoHibernateFloorsBelowOneMinute() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 0)
        let config = try await db.config.get()
        #expect(config.hibernateIdleMinutes == Config.minHibernateIdleMinutes)
    }

    /// `setAutoHibernate` clamps on write, but a row can also end up
    /// out-of-range some other way — hand-edited SQL, a value written by a
    /// different daemon build. `ConfigRecord.toModel()` must clamp on READ
    /// too, so every consumer sees a bounded value regardless of what's
    /// actually stored in the row.
    @Test func readClampsOutOfRangeStoredValue() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.write { conn in
            try conn.execute(
                sql: "UPDATE config SET hibernate_idle_minutes = ? WHERE id = ?",
                arguments: [Config.maxHibernateIdleMinutes + 1_000, ConfigStore.singletonID]
            )
        }
        let aboveCeiling = try await db.config.get()
        #expect(aboveCeiling.hibernateIdleMinutes == Config.maxHibernateIdleMinutes)

        try await db.writerForTests.write { conn in
            try conn.execute(
                sql: "UPDATE config SET hibernate_idle_minutes = ? WHERE id = ?",
                arguments: [0, ConfigStore.singletonID]
            )
        }
        let belowFloor = try await db.config.get()
        #expect(belowFloor.hibernateIdleMinutes == Config.minHibernateIdleMinutes)
    }
}
