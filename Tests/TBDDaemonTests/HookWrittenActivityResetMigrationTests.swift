import Foundation
import GRDB
import Testing
import TBDShared
@testable import TBDDaemonLib

/// Tier 1. `20261030170000_reset_hook_written_activity` resets the activity
/// columns of every live terminal row a hook wrote — no hook writes them any
/// more, so the value would otherwise stand forever — and keeps rows the
/// program status store wrote, and parked or suspended rows.
/// Design: `docs/specs/2026-10-30-osc-only-agent-status-design.md`, "Upgrading".
@Suite struct HookWrittenActivityResetMigrationTests {
    private static let migrationID = "20261030170000_reset_hook_written_activity"
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private static let reportedAt = Date(timeIntervalSince1970: 1_700_000_100)
    private static let hookSource = #"{"kind":"hook","detail":"Notification"}"#

    /// The six columns the migration resets, as the row holds them.
    private struct ActivityColumns: Equatable {
        var activityState: String?
        var source: String?
        var observedAt: Date?
        var orderObservedAt: Date?
        var reason: String?
        var reasonObservedAt: Date?

        static let reset = ActivityColumns(activityState: "unknown")
    }

    /// One terminal row to seed: its activity columns and park stamps.
    private struct Seed {
        let id = UUID().uuidString
        var columns: ActivityColumns
        var hibernatedAt: Date? = nil
        var suspendedAt: Date? = nil
    }

    private static func hookWritten(_ state: String = "waiting_for_user") -> ActivityColumns {
        ActivityColumns(
            activityState: state,
            source: hookSource,
            observedAt: epoch,
            orderObservedAt: epoch,
            reason: FactColumnJSON.encode(AwaitingInputReason(
                message: "Allow Bash?", hookEventName: "Notification",
                notificationType: "permission_prompt")),
            reasonObservedAt: epoch)
    }

    /// Migrate a database to the end of the frozen block, seed `seeds` naming
    /// frozen-block columns only, migrate through this migration, and read
    /// each row's activity columns back in seed order.
    private static func migrated(_ seeds: [Seed]) throws -> [ActivityColumns] {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: SchemaBaselineDriftTests.frozenBlockLastIdentifier)

        let repoID = UUID().uuidString
        let worktreeID = UUID().uuidString
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                    VALUES (?, '/tmp/activity-reset-repo', 'Reset', 'main', ?)
                    """,
                arguments: [repoID, epoch])
            try db.execute(
                sql: """
                    INSERT INTO worktree
                        (id, repoID, name, displayName, branch, path, status, createdAt, tmuxServer)
                    VALUES (?, ?, 'reset', 'reset', 'main', '/tmp/activity-reset-wt',
                            'active', ?, 'tbd-activity-reset')
                    """,
                arguments: [worktreeID, repoID, epoch])
            for seed in seeds {
                let columns = seed.columns
                try db.execute(
                    sql: """
                        INSERT INTO terminal
                            (id, worktreeID, tmuxWindowID, tmuxPaneID, createdAt,
                             activityState, activityStateSource, activityStateObservedAt,
                             activityStateOrderObservedAt, awaitingInputReason,
                             awaitingInputObservedAt, hibernatedAt, suspendedAt)
                        VALUES (?, ?, '@1', '%1', ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        seed.id, worktreeID, epoch,
                        columns.activityState, columns.source, columns.observedAt,
                        columns.orderObservedAt, columns.reason, columns.reasonObservedAt,
                        seed.hibernatedAt, seed.suspendedAt,
                    ])
            }
        }

        try migrator.migrate(queue, upTo: migrationID)

        return try queue.read { db in
            try seeds.map { seed in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT activityState, activityStateSource, activityStateObservedAt,
                               activityStateOrderObservedAt, awaitingInputReason,
                               awaitingInputObservedAt
                        FROM terminal WHERE id = ?
                        """,
                    arguments: [seed.id])
                return ActivityColumns(
                    activityState: row?["activityState"],
                    source: row?["activityStateSource"],
                    observedAt: row?["activityStateObservedAt"],
                    orderObservedAt: row?["activityStateOrderObservedAt"],
                    reason: row?["awaitingInputReason"],
                    reasonObservedAt: row?["awaitingInputObservedAt"])
            }
        }
    }

    @Test func aHookWrittenLiveRowBecomesUnknownWithNoWaitReason() throws {
        let waiting = Seed(columns: Self.hookWritten("waiting_for_user"))
        let working = Seed(columns: Self.hookWritten("working"))
        let after = try Self.migrated([waiting, working])
        #expect(after == [.reset, .reset])
    }

    @Test func aRowWithNoSourceIsReset() throws {
        var columns = Self.hookWritten("working")
        columns.source = nil
        let after = try Self.migrated([Seed(columns: columns)])
        #expect(after == [.reset])
    }

    @Test func aStoreWrittenRowKeepsItsValue() throws {
        let stored = ActivityColumns(
            activityState: "waiting_for_user",
            source: FactColumnJSON.encode(FactSource.programStatus),
            observedAt: Self.reportedAt,
            orderObservedAt: Self.reportedAt,
            reason: FactColumnJSON.encode(AwaitingInputReason(
                message: "", programStatusBlock: ProgramStatusBlock(kind: .permission, taskID: nil))),
            reasonObservedAt: Self.reportedAt)
        let after = try Self.migrated([Seed(columns: stored), Seed(columns: Self.hookWritten())])
        #expect(after == [stored, .reset])
    }

    @Test func aParkedRowKeepsItsValue() throws {
        let parked = ActivityColumns(
            activityState: "idle",
            source: FactColumnJSON.encode(FactSource.database),
            observedAt: Self.epoch,
            orderObservedAt: Self.epoch)
        let after = try Self.migrated([
            Seed(columns: parked, hibernatedAt: Self.epoch),
            Seed(columns: Self.hookWritten()),
        ])
        #expect(after == [parked, .reset])
    }

    @Test func aSuspendedRowKeepsItsValue() throws {
        let suspended = Self.hookWritten("idle")
        let after = try Self.migrated([
            Seed(columns: suspended, suspendedAt: Self.epoch),
            Seed(columns: Self.hookWritten()),
        ])
        #expect(after == [suspended, .reset])
    }

    /// The migration names the store's source as a literal; this pins that
    /// literal to what the store's writer actually stores.
    @Test func theMigrationMatchesTheEncodedSource() {
        #expect(FactColumnJSON.encode(FactSource.programStatus) == #"{"kind":"program-status"}"#)
    }
}
