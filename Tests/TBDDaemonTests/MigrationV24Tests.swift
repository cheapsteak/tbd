import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct MigrationV24Tests {

    @Test func conductorTableIsDropped() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let row = try Row.fetchOne(
                dbConn,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'conductor'"
            )
            #expect(row == nil, "v24 should drop the conductor table created in v10")
        }
    }

    @Test func conductorPseudoRepoIsDeleted() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let row = try Row.fetchOne(
                dbConn,
                sql: "SELECT id FROM repo WHERE id = ?",
                arguments: ["00000000-0000-0000-0000-000000000001"]
            )
            #expect(row == nil, "v24 should delete the synthetic conductor pseudo-repo inserted by v10")
        }
    }

    @Test func conductorStatusWorktreesAreDeleted() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let count = try Int.fetchOne(
                dbConn,
                sql: "SELECT COUNT(*) FROM worktree WHERE status = 'conductor'"
            ) ?? 0
            #expect(count == 0, "v24 should delete any worktree row with the legacy conductor status")
        }
    }

    /// Regression test for the v24 FK-violation crash: if any child-table rows
    /// (terminal, notification, or note) still reference a conductor worktree
    /// when v24 runs, the migration must clean them up before deleting the
    /// worktree. Previously v24 deleted the worktree first, which caused a
    /// FOREIGN KEY constraint violation at transaction commit (SQLite error
    /// 19 from `PRAGMA foreign_key_check`), rolling back the migration and
    /// fatal-crashing the daemon on every restart.
    @Test func v24CleansUpOrphanTerminalsBeforeDeletingConductorWorktree() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()

        // 1. Migrate up to v23 — the state immediately before the buggy v24.
        try migrator.migrate(queue, upTo: "v23_worktree_parent")

        // 2. Insert a repo, a worktree with status='conductor', and child rows
        //    for all three FK-referencing tables (terminal, notification, note)
        //    — mirroring the live production state that originally hit this bug.
        let repoID = "11111111-1111-1111-1111-111111111111"
        let worktreeID = "AD1CBCD0-0000-0000-0000-000000000000"
        let terminalID = "B8BD7929-0000-0000-0000-000000000000"
        let notificationID = "C0000000-0000-0000-0000-000000000000"
        let noteID = "D0000000-0000-0000-0000-000000000000"
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                VALUES (?, '/tmp/v24-orphan-repo', 'V24Orphan', 'main', ?)
                """,
                arguments: [repoID, Date()]
            )
            try db.execute(
                sql: """
                INSERT INTO worktree
                  (id, repoID, name, displayName, branch, path, status, createdAt, tmuxServer)
                VALUES (?, ?, 'conductor', 'conductor', 'main',
                        '/tmp/v24-orphan-repo/conductor', 'conductor', ?, 'tbd-v24-orphan')
                """,
                arguments: [worktreeID, repoID, Date()]
            )
            try db.execute(
                sql: """
                INSERT INTO terminal
                  (id, worktreeID, tmuxWindowID, tmuxPaneID, label, createdAt)
                VALUES (?, ?, '@0', '%0', 'conductor:commerce-manager', ?)
                """,
                arguments: [terminalID, worktreeID, Date()]
            )
            try db.execute(
                sql: """
                INSERT INTO notification
                  (id, worktreeID, type, message, read, createdAt)
                VALUES (?, ?, 'taskComplete', 'Conductor finished', 0, ?)
                """,
                arguments: [notificationID, worktreeID, Date()]
            )
            try db.execute(
                sql: """
                INSERT INTO note
                  (id, worktreeID, title, content, createdAt, updatedAt)
                VALUES (?, ?, 'conductor note', '', ?, ?)
                """,
                arguments: [noteID, worktreeID, Date(), Date()]
            )
        }

        // 3. Run the remaining migrations (i.e. v24). This must NOT throw.
        try migrator.migrate(queue)

        // 4. Verify: conductor worktree gone, conductor table dropped, and no
        //    child rows in terminal, notification, or note still reference the
        //    now-deleted worktree.
        try queue.read { db in
            let worktreeCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM worktree WHERE id = ?",
                arguments: [worktreeID]
            ) ?? -1
            #expect(worktreeCount == 0, "conductor worktree should be deleted")

            let conductorTable = try Row.fetchOne(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'conductor'"
            )
            #expect(conductorTable == nil, "conductor table should be dropped")

            let orphanTerminalCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM terminal WHERE id = ?",
                arguments: [terminalID]
            ) ?? -1
            #expect(orphanTerminalCount == 0, "orphan conductor terminal should be deleted")

            let orphanNotificationCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM notification WHERE id = ?",
                arguments: [notificationID]
            ) ?? -1
            #expect(orphanNotificationCount == 0, "orphan conductor notification should be deleted")

            let orphanNoteCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM note WHERE id = ?",
                arguments: [noteID]
            ) ?? -1
            #expect(orphanNoteCount == 0, "orphan conductor note should be deleted")
        }
    }
}
