import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct LocalAgentSessionMigrationTests {
    @Test func upgradeSeedsOnlyIdentifiedClaudeTerminalsAndAddsNullableArchive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-catalog-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("claude-session.jsonl")
        let untracked = directory.appendingPathComponent("filesystem-only.jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        try Data("{}\n".utf8).write(to: untracked)
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: "20261107184853_phone_control")
        let worktreeID = UUID().uuidString
        let terminalID = UUID().uuidString
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO worktree (id, name, displayName, branch, path, status, createdAt, tmuxServer)
                VALUES (?, 'acme', 'Acme', 'main', '/synthetic/worktree', 'active', ?, 'tbd-test')
                """, arguments: [worktreeID, epoch])
            for (id, kind, session, transcript) in [
                (terminalID, "claude", "claude-session", transcript.path),
                (UUID().uuidString, "codex", "codex-session", "/synthetic/codex.jsonl"),
                (UUID().uuidString, "shell", "shell-session", "/synthetic/shell.jsonl"),
                (UUID().uuidString, "claude", "", "/synthetic/empty.jsonl")
            ] {
                try db.execute(sql: """
                    INSERT INTO terminal (id, worktreeID, tmuxWindowID, tmuxPaneID, kind,
                                          claudeSessionID, transcriptPath, createdAt)
                    VALUES (?, ?, '@1', '%1', ?, ?, ?, ?)
                    """, arguments: [id, worktreeID, kind, session, transcript, epoch])
            }
        }
        try migrator.migrate(queue)
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM local_agent_session")
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            #expect(UUID(uuidString: row["id"]) != nil)
            #expect(row["worktree_id"] as String == worktreeID)
            #expect(row["terminal_id"] as String == terminalID)
            #expect(row["agent_kind"] as String == "claude")
            #expect(row["session_id"] as String == "claude-session")
            #expect(row["transcript_path"] as String == transcript.path)
            #expect(!rows.contains { $0["session_id"] as String == "filesystem-only" })
            #expect(row["first_observed_at"] as Date == epoch)
            #expect(row["last_observed_at"] as Date == epoch)
            let column = try #require(try Row.fetchAll(db, sql: "PRAGMA table_info(worktree)")
                .first { $0["name"] as String == "archived_agent_tabs" })
            #expect(column["notnull"] as Int == 0)
            #expect((column["dflt_value"] as DatabaseValue).isNull)
            #expect(try String.fetchOne(db, sql: "SELECT archived_agent_tabs FROM worktree") == nil)
            let foreignKeys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(local_agent_session)")
            #expect(foreignKeys.contains { $0["from"] as String == "worktree_id" && $0["on_delete"] as String == "CASCADE" })
            #expect(foreignKeys.contains { $0["from"] as String == "terminal_id" && $0["on_delete"] as String == "SET NULL" })
            let indexes = try db.indexes(on: "local_agent_session")
            #expect(indexes.contains { $0.isUnique && $0.columns == ["worktree_id", "agent_kind", "session_id"] })
        }
    }
}
