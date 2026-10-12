import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("TerminalStore server name")
struct TerminalServerNameStoreTests {
    /// The last migration before the column. Update if `main` lands another
    /// migration between this one and the new file.
    private static let lastIdentifierBeforeTheColumn = "20261010025458_config_transcript_prompt_answer"

    private func makeWorktree(_ db: TBDDatabase) async throws -> Worktree {
        try await db.worktrees.createScratch(
            name: "wt", displayName: "wt",
            path: "/tmp/tbd-nonexistent-\(UUID().uuidString)", tmuxServer: "tbd-test")
    }

    @Test func anOrdinaryRowHasNoServerName() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db)
        let t = try await db.terminals.create(worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
        #expect(t.serverName == nil)
        #expect(try #require(try await db.terminals.get(id: t.id)).serverName == nil)
    }

    @Test func aServerNameIsStampedInTheInsertAndReadsBack() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db)
        let t = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1", label: "Web app",
            kind: .shell, serverName: "web")
        #expect(t.serverName == "web")
        let stored = try await db.writerForTests.read { conn in
            try String.fetchOne(conn, sql: "SELECT server_name FROM terminal WHERE id = ?",
                                arguments: [t.id.uuidString])
        }
        #expect(stored == "web", "the model field must land in the snake_case column")
        #expect(try await db.terminals.list(worktreeID: wt.id).first?.serverName == "web")
    }

    /// `terminal.recreateWindow` rebuilds a dead server tab as a plain login
    /// shell. The row must stop naming the server, or the shell would read as
    /// the running server and stop or archive would signal its group.
    @Test func recreatingAServerTabAsAShellClearsItsServerName() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db)
        let t = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1", label: "Web app",
            kind: .shell, serverName: "web")
        let token = try await db.terminals.replaceRecreatedShellWindow(
            id: t.id, expectedIncarnation: TerminalSessionIncarnation(terminal: t),
            windowID: "@2", paneID: "%2", at: Date())
        #expect(token != nil)
        let rebuilt = try #require(try await db.terminals.get(id: t.id))
        #expect(rebuilt.tmuxPaneID == "%2")
        #expect(rebuilt.serverName == nil)
    }

    @Test func theFieldSurvivesTheWire() throws {
        var t = Terminal(worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1")
        t.serverName = "web"
        let decoded = try JSONDecoder().decode(Terminal.self, from: try JSONEncoder().encode(t))
        #expect(decoded.serverName == "web")
    }

    @Test func jsonWithoutTheKeyDecodesNil() throws {
        let t = Terminal(worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1")
        var object = try #require(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(t)) as? [String: Any])
        object.removeValue(forKey: "serverName")
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(Terminal.self, from: data).serverName == nil)
    }

    @Test func historyServerFieldsReachTheirColumnsAndReadBack() async throws {
        let db = try TBDDatabase(inMemory: true, terminalHistoryDir: "/tmp/tbd-nonexistent-\(UUID().uuidString)")
        let wt = try await makeWorktree(db)
        let entry = TerminalHistoryEntry(
            id: UUID(), worktreeID: wt.id, label: "Web app", kind: .shell,
            lineCount: 1, serverName: "web", exitCode: 127)
        try await db.writerForTests.write { try TerminalHistoryRecord(from: entry).insert($0) }
        let row = try await db.writerForTests.read { conn in
            try Row.fetchOne(conn, sql: "SELECT serverName, exitCode FROM terminal_history WHERE id = ?",
                             arguments: [entry.id.uuidString])
        }
        let stored = try #require(row)
        #expect(stored["serverName"] as String? == "web")
        #expect(stored["exitCode"] as Int? == 127)
        let listed = try #require(try await db.terminalHistory.list(worktreeID: wt.id).first)
        #expect(listed.serverName == "web")
        #expect(listed.exitCode == 127)
    }

    @Test func historyJSONWithoutTheServerKeysDecodesNil() throws {
        let entry = TerminalHistoryEntry(id: UUID(), worktreeID: UUID(), lineCount: 2)
        var object = try #require(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(entry)) as? [String: Any])
        object.removeValue(forKey: "serverName")
        object.removeValue(forKey: "exitCode")
        let decoded = try JSONDecoder().decode(
            TerminalHistoryEntry.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(decoded.serverName == nil)
        #expect(decoded.exitCode == nil)
    }

    /// A history row written before the migration reads NULL in both new
    /// columns — a DEFAULT clause would redden this.
    @Test func aHistoryRowWrittenBeforeTheMigrationReadsNil() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: Self.lastIdentifierBeforeTheColumn)
        let entryID = UUID().uuidString
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO terminal_history (id, worktreeID, closedAt, lineCount)
                VALUES (?, ?, ?, 3)
                """, arguments: [entryID, UUID().uuidString, Date(timeIntervalSince1970: 1_700_000_000)])
        }
        try migrator.migrate(queue)
        try queue.read { db in
            let row = try #require(try Row.fetchOne(
                db, sql: "SELECT serverName, exitCode FROM terminal_history WHERE id = ?", arguments: [entryID]))
            #expect((row["serverName"] as DatabaseValue).isNull)
            #expect((row["exitCode"] as DatabaseValue).isNull)
            let record = try #require(try TerminalHistoryRecord.fetchOne(db, key: entryID))
            let model = try #require(record.toModel())
            #expect(model.serverName == nil)
            #expect(model.exitCode == nil)
        }
    }

    /// A row written before the migration reads NULL, not "" — a DEFAULT
    /// clause on the migration would redden this.
    @Test func aRowWrittenBeforeTheMigrationReadsNil() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: Self.lastIdentifierBeforeTheColumn)
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let repoID = UUID().uuidString, worktreeID = UUID().uuidString, terminalID = UUID().uuidString
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                VALUES (?, '/tmp/server-name-repo', 'Acme', 'main', ?)
                """, arguments: [repoID, epoch])
            try db.execute(sql: """
                INSERT INTO worktree (id, repoID, name, displayName, branch, path, status, createdAt, tmuxServer)
                VALUES (?, ?, 'w', 'w', 'main', '/tmp/server-name-wt', 'active', ?, 'tbd-server-name')
                """, arguments: [worktreeID, repoID, epoch])
            try db.execute(sql: """
                INSERT INTO terminal (id, worktreeID, tmuxWindowID, tmuxPaneID, createdAt)
                VALUES (?, ?, '@1', '%1', ?)
                """, arguments: [terminalID, worktreeID, epoch])
        }
        #expect(!(try queue.read { try $0.columns(in: "terminal").map(\.name) }).contains("server_name"))
        try migrator.migrate(queue)
        try queue.read { db in
            let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM terminal WHERE id = ?", arguments: [terminalID]))
            let raw: DatabaseValue = row["server_name"]
            #expect(raw.isNull)
            let record = try #require(try TerminalRecord.fetchOne(db, key: terminalID))
            #expect(try #require(record.toModel()).serverName == nil)
        }
    }
}
