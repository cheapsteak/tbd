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
        // Defaults: idle sweep OFF (forced off by migration v50), 30 min.
        let initial = try await db.config.get()
        #expect(initial.autoHibernateEnabled == false)
        #expect(initial.hibernateIdleMinutes == Config.defaultHibernateIdleMinutes)

        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 45)
        let updated = try await db.config.get()
        #expect(updated.autoHibernateEnabled == true)
        #expect(updated.hibernateIdleMinutes == 45)
    }

    /// Migration v50 forces the idle-sweep master switch off on a fresh DB, and
    /// a subsequent user opt-in must round-trip (the migration must not fight a
    /// later `setAutoHibernate(enabled: true, ...)`).
    @Test func migrationV50ForcesIdleSweepOffButAllowsOptIn() async throws {
        let db = try TBDDatabase(inMemory: true)
        // A fresh DB runs every migration through v50 → sweep off.
        #expect(try await db.config.get().autoHibernateEnabled == false)

        // User opts back in; the value must stick.
        try await db.config.setAutoHibernate(
            enabled: true, idleMinutes: Config.defaultHibernateIdleMinutes)
        #expect(try await db.config.get().autoHibernateEnabled == true)

        // ...and opting back out persists too. This is the only direct
        // config-level assertion of the false write path now that
        // `configHibernationDefaultsAndRoundTrip` was repointed at the true
        // case — the toggle's off-branch must round-trip through `get()`.
        try await db.config.setAutoHibernate(
            enabled: false, idleMinutes: Config.defaultHibernateIdleMinutes)
        #expect(try await db.config.get().autoHibernateEnabled == false)
    }

    @Test func configIdleMinutesFlooredAtOne() async throws {
        let db = try TBDDatabase(inMemory: true)
        // A zero/negative can't be persisted — it would make the sweep hibernate
        // everything immediately. Floored to 1.
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 0)
        #expect(try await db.config.get().hibernateIdleMinutes == 1)
    }

    // MARK: - v40: unify suspend/hibernate (backfill suspendedAt → hibernatedAt)

    /// The v40 migration converges every parked row on the authoritative
    /// `hibernatedAt` column: for any row with `suspendedAt` set but
    /// `hibernatedAt` NULL, it copies suspendedAt into hibernatedAt (and leaves
    /// suspendedAt in place as legacy-read). This exercises the same UPDATE the
    /// migration body runs, then re-runs it to prove idempotency.
    @Test func v40BackfillsLegacySuspendedIntoHibernated() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v40-repo-\(UUID().uuidString)", displayName: "V40", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/v40-wt-\(UUID().uuidString)", tmuxServer: "tbd-v40")

        // Legacy-parked row: only suspendedAt set (hibernatedAt NULL) — the state
        // a pre-merge Suspend feature left behind.
        let legacy = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "s-legacy", kind: .claude)
        try await db.terminals.setSuspended(id: legacy.id, sessionID: "s-legacy")

        // An awake row (no parked timestamps) must be untouched by the backfill.
        let awake = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: "claude", claudeSessionID: "s-awake", kind: .claude)

        let backfillSQL = """
            UPDATE terminal
            SET hibernatedAt = suspendedAt
            WHERE suspendedAt IS NOT NULL AND hibernatedAt IS NULL
            """

        // Run the backfill (the v40 body).
        try await db.writerForTests.write { dbConn in
            try dbConn.execute(sql: backfillSQL)
        }

        let migratedLegacy = try await db.terminals.get(id: legacy.id)
        #expect(migratedLegacy?.suspendedAt != nil, "suspendedAt is preserved (legacy read)")
        #expect(migratedLegacy?.hibernatedAt != nil, "backfill must populate hibernatedAt")
        #expect(migratedLegacy?.hibernatedAt == migratedLegacy?.suspendedAt,
                "hibernatedAt must equal the copied suspendedAt")
        #expect(migratedLegacy?.isParked == true)

        let migratedAwake = try await db.terminals.get(id: awake.id)
        #expect(migratedAwake?.suspendedAt == nil)
        #expect(migratedAwake?.hibernatedAt == nil, "an awake row must not be backfilled")

        // Idempotency: re-running must change nothing (the row no longer matches
        // the WHERE clause).
        let hibBefore = migratedLegacy?.hibernatedAt
        try await db.writerForTests.write { dbConn in
            try dbConn.execute(sql: backfillSQL)
        }
        let afterRerun = try await db.terminals.get(id: legacy.id)
        #expect(afterRerun?.hibernatedAt == hibBefore, "re-running the backfill is a no-op")
    }

    /// A row already parked via the authoritative column (hibernatedAt set,
    /// suspendedAt NULL) is left as-is by the backfill — it doesn't match the
    /// WHERE clause.
    @Test func v40LeavesAuthoritativeHibernatedRowUntouched() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v40b-repo-\(UUID().uuidString)", displayName: "V40", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/v40b-wt-\(UUID().uuidString)", tmuxServer: "tbd-v40")
        let t = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "s-1", kind: .claude)
        try await db.terminals.setHibernated(id: t.id, sessionID: "s-1")

        try await db.writerForTests.write { dbConn in
            try dbConn.execute(sql: """
                UPDATE terminal
                SET hibernatedAt = suspendedAt
                WHERE suspendedAt IS NOT NULL AND hibernatedAt IS NULL
                """)
        }
        let after = try await db.terminals.get(id: t.id)
        #expect(after?.hibernatedAt != nil)
        #expect(after?.suspendedAt == nil, "authoritative-only row: suspendedAt stays NULL")
    }
}
