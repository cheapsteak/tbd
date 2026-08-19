import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib

@Suite struct MigrationV86TerminalSessionOrderTests {
    @Test func forwardMigrationAddsNullableSessionOrderingWatermark() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: "v85_terminal_activity_order")
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let repoID = UUID().uuidString
        let worktreeID = UUID().uuidString
        let terminalID = UUID().uuidString
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                    VALUES (?, '/tmp/v86-repo', 'V86', 'main', ?)
                    """,
                arguments: [repoID, epoch]
            )
            try db.execute(
                sql: """
                    INSERT INTO worktree
                        (id, repoID, name, displayName, branch, path, status, createdAt, tmuxServer)
                    VALUES (?, ?, 'w', 'w', 'main', '/tmp/v86-wt', 'active', ?, 'tbd-v86')
                    """,
                arguments: [worktreeID, repoID, epoch]
            )
            try db.execute(
                sql: """
                    INSERT INTO terminal
                        (id, worktreeID, tmuxWindowID, tmuxPaneID, createdAt,
                         claudeSessionID, transcriptPath, activityStateOrderObservedAt)
                    VALUES (?, ?, '@1', '%1', ?, 'current-session', '/tmp/current.jsonl', ?)
                    """,
                arguments: [terminalID, worktreeID, epoch, epoch]
            )
        }

        let columnsBefore = try queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(terminal)")
                .compactMap { $0["name"] as String? }
        }
        #expect(!columnsBefore.contains("sessionOrderObservedAt"))

        try migrator.migrate(queue, upTo: "v86_terminal_session_order")

        let column = try queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(terminal)")
                .first { ($0["name"] as String?) == "sessionOrderObservedAt" }
        }
        #expect(column != nil)
        #expect((column?["dflt_value"] as String?)?.uppercased() == "NULL")

        let row = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM terminal WHERE id = ?", arguments: [terminalID])
        }
        #expect((row?["claudeSessionID"] as String?) == "current-session")
        #expect((row?["transcriptPath"] as String?) == "/tmp/current.jsonl")
        #expect((row?["activityStateOrderObservedAt"] as Date?) == epoch)
        #expect((row?["sessionOrderObservedAt"] as Date?) == nil)
    }
}
