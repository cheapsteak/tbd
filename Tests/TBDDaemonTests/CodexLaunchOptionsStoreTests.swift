import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("TerminalStore Codex launch options")
struct CodexLaunchOptionsStoreTests {
    /// The last migration before the column. Update if `main` lands another
    /// migration between this one and the new file.
    private static let lastIdentifierBeforeTheColumn = "20261011235918_dev_server_columns"

    private static let options = CodexLaunchOptions(
        model: "acme-model", disabledFeatures: ["computer_use", "browser_use"])

    private func makeWorktree(_ db: TBDDatabase) async throws -> Worktree {
        try await db.worktrees.createScratch(
            name: "wt", displayName: "wt",
            path: "/tmp/tbd-nonexistent-\(UUID().uuidString)", tmuxServer: "tbd-test")
    }

    private func storedColumn(_ db: TBDDatabase, _ id: UUID) async throws -> String? {
        try await db.writerForTests.read { conn in
            try String.fetchOne(
                conn, sql: "SELECT codex_launch_options FROM terminal WHERE id = ?",
                arguments: [id.uuidString])
        }
    }

    @Test func aLaunchWithNoOptionsRecordsNothing() {
        #expect(CodexLaunchOptions.recorded(model: nil, disabledFeatures: []) == nil)
        #expect(CodexLaunchOptions.recorded(model: "", disabledFeatures: []) == nil)
        #expect(CodexLaunchOptions.recorded(model: "acme-model", disabledFeatures: [])
                == CodexLaunchOptions(model: "acme-model"))
        #expect(CodexLaunchOptions.recorded(model: "", disabledFeatures: ["computer_use"])
                == CodexLaunchOptions(disabledFeatures: ["computer_use"]))
    }

    @Test func anOrdinaryRowHasNoOptions() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db)
        let t = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .codex)
        #expect(t.codexLaunchOptions == nil)
        #expect(try await storedColumn(db, t.id) == nil)
        #expect(try #require(try await db.terminals.get(id: t.id)).codexLaunchOptions == nil)
    }

    @Test func optionsAreStampedInTheInsertAndReadBack() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db)
        let t = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.codex, kind: .codex, codexLaunchOptions: Self.options)
        #expect(t.codexLaunchOptions == Self.options)
        let stored = try #require(try await storedColumn(db, t.id))
        #expect(try JSONDecoder().decode(CodexLaunchOptions.self, from: Data(stored.utf8))
                == Self.options, "the model field must land in the snake_case column as JSON")
        #expect(try await db.terminals.list(worktreeID: wt.id).first?.codexLaunchOptions
                == Self.options)
    }

    /// An unreadable blob must cost only the options, never the row: the
    /// relaunch then falls back to the default command.
    @Test func anUnreadableColumnReadsNilWithoutLosingTheRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db)
        let t = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .codex)
        try await db.writerForTests.write { conn in
            try conn.execute(
                sql: "UPDATE terminal SET codex_launch_options = 'not json' WHERE id = ?",
                arguments: [t.id.uuidString])
        }
        let read = try #require(try await db.terminals.get(id: t.id))
        #expect(read.kind == .codex)
        #expect(read.codexLaunchOptions == nil)
    }

    /// A Codex tab recreated as a plain shell launches no Codex, so it must
    /// stop carrying Codex options.
    @Test func recreatingAsAShellClearsTheOptions() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db)
        let t = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.codex, kind: .codex, codexLaunchOptions: Self.options)
        let token = try await db.terminals.replaceRecreatedShellWindow(
            id: t.id, expectedIncarnation: TerminalSessionIncarnation(terminal: t),
            windowID: "@2", paneID: "%2", at: Date())
        #expect(token != nil)
        let rebuilt = try #require(try await db.terminals.get(id: t.id))
        #expect(rebuilt.kind == .shell)
        #expect(rebuilt.codexLaunchOptions == nil)
        #expect(try await storedColumn(db, t.id) == nil)
    }

    /// The Codex replacement keeps the tab's Codex identity, so it keeps the
    /// options for the next relaunch too.
    @Test func replacingACodexWindowKeepsTheOptions() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db)
        let t = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.codex, kind: .codex, codexLaunchOptions: Self.options)
        let token = try await db.terminals.replaceRecreatedCodexWindow(
            id: t.id, expectedIncarnation: TerminalSessionIncarnation(terminal: t),
            windowID: "@2", paneID: "%2", at: Date())
        #expect(token != nil)
        #expect(try #require(try await db.terminals.get(id: t.id)).codexLaunchOptions
                == Self.options)
    }

    @Test func theFieldSurvivesTheWire() throws {
        var t = Terminal(worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1")
        t.codexLaunchOptions = Self.options
        let decoded = try JSONDecoder().decode(Terminal.self, from: try JSONEncoder().encode(t))
        #expect(decoded.codexLaunchOptions == Self.options)
    }

    @Test func jsonWithoutTheKeyDecodesNil() throws {
        let t = Terminal(worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1")
        var object = try #require(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(t)) as? [String: Any])
        object.removeValue(forKey: "codexLaunchOptions")
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(Terminal.self, from: data).codexLaunchOptions == nil)
    }

    @Test func optionsWithoutAFeatureListDecodeAsNone() throws {
        let decoded = try JSONDecoder().decode(
            CodexLaunchOptions.self, from: Data(#"{"model":"acme-model"}"#.utf8))
        #expect(decoded == CodexLaunchOptions(model: "acme-model"))
    }

    /// A row written before the migration reads NULL — a DEFAULT clause on the
    /// migration would redden this — and relaunches with the default command.
    @Test func aRowWrittenBeforeTheMigrationReadsNil() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: Self.lastIdentifierBeforeTheColumn)
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let repoID = UUID().uuidString, worktreeID = UUID().uuidString, terminalID = UUID().uuidString
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                VALUES (?, '/tmp/codex-options-repo', 'Acme', 'main', ?)
                """, arguments: [repoID, epoch])
            try db.execute(sql: """
                INSERT INTO worktree (id, repoID, name, displayName, branch, path, status, createdAt, tmuxServer)
                VALUES (?, ?, 'w', 'w', 'main', '/tmp/codex-options-wt', 'active', ?, 'tbd-codex-options')
                """, arguments: [worktreeID, repoID, epoch])
            try db.execute(sql: """
                INSERT INTO terminal (id, worktreeID, tmuxWindowID, tmuxPaneID, label, kind, createdAt)
                VALUES (?, ?, '@1', '%1', 'codex', 'codex', ?)
                """, arguments: [terminalID, worktreeID, epoch])
        }
        #expect(!(try queue.read { try $0.columns(in: "terminal").map(\.name) })
            .contains("codex_launch_options"))
        try migrator.migrate(queue)
        try queue.read { db in
            let row = try #require(try Row.fetchOne(
                db, sql: "SELECT * FROM terminal WHERE id = ?", arguments: [terminalID]))
            let raw: DatabaseValue = row["codex_launch_options"]
            #expect(raw.isNull)
            let record = try #require(try TerminalRecord.fetchOne(db, key: terminalID))
            #expect(try #require(record.toModel()).codexLaunchOptions == nil)
        }
    }
}
