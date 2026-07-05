import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct MigrationV39HibernationTests {

    @Test func hibernationColumnsExist() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let terminalCols = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(terminal)")
                .compactMap { $0["name"] as String? }
            #expect(terminalCols.contains("hibernatedAt"))
            #expect(terminalCols.contains("keepWarm"))
            let configCols = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(config)")
                .compactMap { $0["name"] as String? }
            #expect(configCols.contains("auto_hibernate_enabled"))
            #expect(configCols.contains("hibernate_idle_minutes"))
        }
    }

    @Test func terminalHibernationDefaults() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v39-repo-\(UUID().uuidString)", displayName: "V39", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/v39-wt-\(UUID().uuidString)", tmuxServer: "tbd-v39")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1")

        #expect(terminal.hibernatedAt == nil)
        #expect(terminal.keepWarm == false)

        let fetched = try await db.terminals.get(id: terminal.id)
        #expect(fetched?.hibernatedAt == nil)
        #expect(fetched?.keepWarm == false)
    }

    @Test func setHibernatedAndKeepWarmRoundTrip() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v39-repo2-\(UUID().uuidString)", displayName: "V39", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/v39-wt2-\(UUID().uuidString)", tmuxServer: "tbd-v39")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "s-1", kind: .claude)

        try await db.terminals.setHibernated(id: terminal.id, sessionID: "s-1")
        try await db.terminals.setKeepWarm(id: terminal.id, keepWarm: true)
        let hibernated = try await db.terminals.get(id: terminal.id)
        #expect(hibernated?.hibernatedAt != nil)
        #expect(hibernated?.keepWarm == true)

        try await db.terminals.clearHibernated(id: terminal.id)
        let cleared = try await db.terminals.get(id: terminal.id)
        #expect(cleared?.hibernatedAt == nil)
        #expect(cleared?.keepWarm == true)  // keep-warm is independent of hibernation
    }

    @Test func configHibernationDefaultsAndRoundTrip() async throws {
        let db = try TBDDatabase(inMemory: true)
        // Defaults: ON, 30 min.
        let initial = try await db.config.get()
        #expect(initial.autoHibernateEnabled == true)
        #expect(initial.hibernateIdleMinutes == Config.defaultHibernateIdleMinutes)

        try await db.config.setAutoHibernate(enabled: false, idleMinutes: 45)
        let updated = try await db.config.get()
        #expect(updated.autoHibernateEnabled == false)
        #expect(updated.hibernateIdleMinutes == 45)
    }

    @Test func configIdleMinutesFlooredAtOne() async throws {
        let db = try TBDDatabase(inMemory: true)
        // A zero/negative can't be persisted — it would make the sweep hibernate
        // everything immediately. Floored to 1.
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 0)
        #expect(try await db.config.get().hibernateIdleMinutes == 1)
    }
}
