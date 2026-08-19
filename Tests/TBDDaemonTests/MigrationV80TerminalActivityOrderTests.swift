import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct MigrationV80TerminalActivityOrderTests {
    @Test func forwardMigrationAddsNullableOrderingWatermark() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: "v79_reap_records_quarantine_path")
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let repoID = UUID().uuidString
        let worktreeID = UUID().uuidString
        let terminalID = UUID().uuidString
        let source = FactColumnJSON.encode(FactSource.hookEvent("UserPromptSubmit"))
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                    VALUES (?, '/tmp/v80-repo', 'V80', 'main', ?)
                    """,
                arguments: [repoID, epoch]
            )
            try db.execute(
                sql: """
                    INSERT INTO worktree
                        (id, repoID, name, displayName, branch, path, status, createdAt, tmuxServer)
                    VALUES (?, ?, 'w', 'w', 'main', '/tmp/v80-wt', 'active', ?, 'tbd-v80')
                    """,
                arguments: [worktreeID, repoID, epoch]
            )
            try db.execute(
                sql: """
                    INSERT INTO terminal
                        (id, worktreeID, tmuxWindowID, tmuxPaneID, createdAt,
                         activityState, activityStateSource, activityStateObservedAt)
                    VALUES (?, ?, '@1', '%1', ?, 'working', ?, ?)
                    """,
                arguments: [terminalID, worktreeID, epoch, source, epoch]
            )
        }

        let columnsBefore = try queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(terminal)")
                .compactMap { $0["name"] as String? }
        }
        #expect(!columnsBefore.contains("activityStateOrderObservedAt"))

        try migrator.migrate(queue)

        let column = try queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(terminal)")
                .first { ($0["name"] as String?) == "activityStateOrderObservedAt" }
        }
        #expect(column != nil)
        #expect((column?["dflt_value"] as String?)?.uppercased() == "NULL")

        let record = try queue.read { db in
            try TerminalRecord.fetchOne(db, key: terminalID)
        }
        let terminal = try #require(record?.toModel())
        #expect(terminal.activityState == .working)
        #expect(terminal.activityStateSource == .hookEvent("UserPromptSubmit"))
        #expect(terminal.activityStateObservedAt == epoch)
        #expect(terminal.activityStateOrderObservedAt == nil)
        #expect(terminal.observedActivity?.observedAt == epoch)
    }
}
