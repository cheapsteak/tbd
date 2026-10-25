import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Where a terminal's Claude spawn values are stored
/// (docs/specs/2026-10-24-terminal-plugin-dirs-design.md, "What TBD stores"):
/// one JSON object on the terminal row, a copy on the history entry written
/// when it closes, and a session-id-keyed map on the archived worktree.
/// Tier 1: in-memory database, nothing on disk.
@Suite("Claude spawn extras storage")
struct ClaudeSpawnExtrasStorageTests {
    /// The last migration before the columns. Update if `main` lands another
    /// migration between this one and the new file.
    private static let lastIdentifierBeforeTheColumns = "20261024184718_drop_watch_desk_judge_lease"

    private static let sample = ClaudeSpawnExtras(
        claudeSettingsOverlay: "{\"a\":1}", pluginDirs: ["/p"])

    private func makeDatabase() throws -> TBDDatabase {
        // The history dir is never written: every close here passes no capture.
        try TBDDatabase(
            inMemory: true, terminalHistoryDir: "/tmp/tbd-nonexistent-\(UUID().uuidString)")
    }

    private func makeWorktree(_ db: TBDDatabase) async throws -> Worktree {
        try await db.worktrees.createScratch(
            name: "wt", displayName: "wt",
            path: "/tmp/tbd-nonexistent-\(UUID().uuidString)", tmuxServer: "tbd-test")
    }

    /// Inserts a terminal row carrying `extras` through the record type, the
    /// way every store write reaches the table.
    private func insertTerminal(
        _ db: TBDDatabase, worktreeID: UUID, extras: ClaudeSpawnExtras?
    ) async throws -> Terminal {
        let terminal = Terminal(
            worktreeID: worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
            claudeSessionID: "sess-1", kind: .claude, claudeSpawnExtras: extras)
        try await db.writerForTests.write { try TerminalRecord(from: terminal).insert($0) }
        return terminal
    }

    private func rawColumn(_ db: TBDDatabase, table: String, column: String, id: UUID) async throws -> String? {
        try await db.writerForTests.read { conn in
            try String.fetchOne(conn, sql: "SELECT \(column) FROM \(table) WHERE id = ?",
                                arguments: [id.uuidString])
        }
    }

    // MARK: - Terminal row

    @Test func terminalRowRoundTripsExtras() async throws {
        let db = try makeDatabase()
        let wt = try await makeWorktree(db)
        let inserted = try await insertTerminal(db, worktreeID: wt.id, extras: Self.sample)

        let read = try #require(try await db.terminals.get(id: inserted.id))
        #expect(read.claudeSpawnExtras == Self.sample)
        #expect(try await db.terminals.list(worktreeID: wt.id).first?.claudeSpawnExtras == Self.sample)
        let stored = try #require(try await rawColumn(
            db, table: "terminal", column: "claude_spawn_extras", id: inserted.id))
        #expect(stored.contains("\"pluginDirs\""), "the model field must land in the snake_case column")
    }

    /// A row written by the existing create path, which names no extras.
    @Test func terminalRowWithoutExtrasReadsNil() async throws {
        let db = try makeDatabase()
        let wt = try await makeWorktree(db)
        let created = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude)

        #expect(try #require(try await db.terminals.get(id: created.id)).claudeSpawnExtras == nil)
        #expect(try await rawColumn(
            db, table: "terminal", column: "claude_spawn_extras", id: created.id) == nil)
    }

    /// A stored object that does not decode reads as nothing stored — and the
    /// row itself still reads, on all three tables.
    @Test func undecodableExtrasReadNil() async throws {
        let db = try makeDatabase()
        let wt = try await makeWorktree(db)
        let terminal = try await insertTerminal(db, worktreeID: wt.id, extras: Self.sample)
        await db.terminalHistory.recordOnClose(terminal: terminal, capture: nil)
        try await db.worktrees.archive(
            id: wt.id, claudeSessionIDs: ["s1"], claudeSpawnExtras: ["s1": Self.sample])

        try await db.writerForTests.write { conn in
            try conn.execute(sql: "UPDATE terminal SET claude_spawn_extras = 'not json' WHERE id = ?",
                             arguments: [terminal.id.uuidString])
            try conn.execute(sql: "UPDATE terminal_history SET claudeSpawnExtras = 'not json' WHERE id = ?",
                             arguments: [terminal.id.uuidString])
            try conn.execute(sql: "UPDATE worktree SET archivedClaudeSpawnExtras = '[1]' WHERE id = ?",
                             arguments: [wt.id.uuidString])
        }

        let readTerminal = try #require(try await db.terminals.get(id: terminal.id))
        #expect(readTerminal.claudeSpawnExtras == nil)
        #expect(readTerminal.claudeSessionID == "sess-1")
        let entry = try #require(try await db.terminalHistory.list(worktreeID: wt.id).first)
        #expect(entry.claudeSpawnExtras == nil)
        let readWorktree = try #require(try await db.worktrees.get(id: wt.id))
        #expect(readWorktree.archivedClaudeSpawnExtras == nil)
        #expect(readWorktree.archivedClaudeSessions == ["s1"])
    }

    /// A row written before the migration reads NULL in every new column — a
    /// DEFAULT clause on the migration would redden this.
    @Test func rowsWrittenBeforeTheMigrationReadNil() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: Self.lastIdentifierBeforeTheColumns)
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let repoID = UUID().uuidString, worktreeID = UUID().uuidString
        let terminalID = UUID().uuidString, historyID = UUID().uuidString
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                VALUES (?, '/tmp/spawn-extras-repo', 'Acme', 'main', ?)
                """, arguments: [repoID, epoch])
            try db.execute(sql: """
                INSERT INTO worktree (id, repoID, name, displayName, branch, path, status, createdAt, tmuxServer)
                VALUES (?, ?, 'w', 'w', 'main', '/tmp/spawn-extras-wt', 'active', ?, 'tbd-spawn-extras')
                """, arguments: [worktreeID, repoID, epoch])
            try db.execute(sql: """
                INSERT INTO terminal (id, worktreeID, tmuxWindowID, tmuxPaneID, createdAt)
                VALUES (?, ?, '@1', '%1', ?)
                """, arguments: [terminalID, worktreeID, epoch])
            try db.execute(sql: """
                INSERT INTO terminal_history (id, worktreeID, closedAt, lineCount)
                VALUES (?, ?, ?, 3)
                """, arguments: [historyID, worktreeID, epoch])
        }
        #expect(!(try queue.read { try $0.columns(in: "terminal").map(\.name) }).contains("claude_spawn_extras"))
        try migrator.migrate(queue)
        try queue.read { db in
            let terminal = try #require(try Row.fetchOne(
                db, sql: "SELECT claude_spawn_extras FROM terminal WHERE id = ?", arguments: [terminalID]))
            #expect((terminal["claude_spawn_extras"] as DatabaseValue).isNull)
            let history = try #require(try Row.fetchOne(
                db, sql: "SELECT claudeSpawnExtras FROM terminal_history WHERE id = ?", arguments: [historyID]))
            #expect((history["claudeSpawnExtras"] as DatabaseValue).isNull)
            let worktree = try #require(try Row.fetchOne(
                db, sql: "SELECT archivedClaudeSpawnExtras FROM worktree WHERE id = ?", arguments: [worktreeID]))
            #expect((worktree["archivedClaudeSpawnExtras"] as DatabaseValue).isNull)

            #expect(try #require(try TerminalRecord.fetchOne(db, key: terminalID)?.toModel())
                .claudeSpawnExtras == nil)
            #expect(try #require(try TerminalHistoryRecord.fetchOne(db, key: historyID)?.toModel())
                .claudeSpawnExtras == nil)
            #expect(try #require(try WorktreeRecord.fetchOne(db, key: worktreeID)?.toModel())
                .archivedClaudeSpawnExtras == nil)
        }
    }

    // MARK: - History entry

    @Test func historyEntryCopiesClosingTerminalExtras() async throws {
        let db = try makeDatabase()
        let wt = try await makeWorktree(db)
        let inserted = try await insertTerminal(db, worktreeID: wt.id, extras: Self.sample)
        // Close with the row as the store reads it, as the close paths do.
        let closing = try #require(try await db.terminals.get(id: inserted.id))

        await db.terminalHistory.recordOnClose(terminal: closing, capture: nil)

        let entry = try #require(try await db.terminalHistory.list(worktreeID: wt.id).first)
        #expect(entry.id == inserted.id)
        #expect(entry.claudeSpawnExtras == Self.sample)
        #expect(try await rawColumn(
            db, table: "terminal_history", column: "claudeSpawnExtras", id: inserted.id) != nil)
    }

    /// Only a Claude tab's values reach its history entry. A failed
    /// pre-session hook's shell row keeps the create's values while its tab
    /// lives, and a Codex row could carry some too; neither entry keeps them,
    /// since a reopen of either has no use for them.
    @Test(arguments: [TerminalKind.shell, .codex])
    func historyEntryOfANonClaudeTerminalKeepsNoExtras(kind: TerminalKind) async throws {
        let db = try makeDatabase()
        let wt = try await makeWorktree(db)
        let closing = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: kind == .shell ? TerminalLabel.preSession : TerminalLabel.codex,
            kind: kind, claudeSpawnExtras: Self.sample)
        #expect(try await db.terminals.get(id: closing.id)?.claudeSpawnExtras == Self.sample)

        await db.terminalHistory.recordOnClose(terminal: closing, capture: nil)

        let entry = try #require(try await db.terminalHistory.list(worktreeID: wt.id).first)
        #expect(entry.id == closing.id)
        #expect(entry.kind == kind)
        #expect(entry.claudeSpawnExtras == nil)
        #expect(try await rawColumn(
            db, table: "terminal_history", column: "claudeSpawnExtras", id: closing.id) == nil)
    }

    @Test func historyEntryOfATerminalWithoutExtrasReadsNil() async throws {
        let db = try makeDatabase()
        let wt = try await makeWorktree(db)
        let inserted = try await insertTerminal(db, worktreeID: wt.id, extras: nil)

        await db.terminalHistory.recordOnClose(terminal: inserted, capture: nil)

        let entry = try #require(try await db.terminalHistory.list(worktreeID: wt.id).first)
        #expect(entry.claudeSpawnExtras == nil)
        #expect(try await rawColumn(
            db, table: "terminal_history", column: "claudeSpawnExtras", id: inserted.id) == nil)
    }

    // MARK: - Archived worktree

    @Test func archiveStoresSessionExtrasMap() async throws {
        let db = try makeDatabase()
        let wt = try await makeWorktree(db)

        try await db.worktrees.archive(
            id: wt.id, claudeSessionIDs: ["s1"], claudeSpawnExtras: ["s1": Self.sample])

        let archived = try #require(try await db.worktrees.get(id: wt.id))
        #expect(archived.archivedClaudeSpawnExtras == ["s1": Self.sample])
        #expect(archived.archivedClaudeSessions == ["s1"])
    }

    /// An empty map stores NULL, not `{}`.
    @Test func emptyArchiveMapStoresNil() async throws {
        let db = try makeDatabase()
        let wt = try await makeWorktree(db)

        try await db.worktrees.archive(id: wt.id, claudeSessionIDs: ["s1"], claudeSpawnExtras: [:])

        #expect(try #require(try await db.worktrees.get(id: wt.id)).archivedClaudeSpawnExtras == nil)
        #expect(try await rawColumn(
            db, table: "worktree", column: "archivedClaudeSpawnExtras", id: wt.id) == nil)
    }

    @Test func reviveClearsSessionExtrasMap() async throws {
        let db = try makeDatabase()
        let wt = try await makeWorktree(db)
        try await db.worktrees.archive(
            id: wt.id, claudeSessionIDs: ["s1"], claudeSpawnExtras: ["s1": Self.sample])

        try await db.worktrees.revive(id: wt.id)

        let revived = try #require(try await db.worktrees.get(id: wt.id))
        #expect(revived.archivedClaudeSpawnExtras == nil)
        #expect(revived.archivedClaudeSessions == nil)
    }

    /// A revive that keeps its sessions keeps their values too, and an archive
    /// that passes neither sessions nor values leaves both in place.
    @Test func reviveKeepingSessionsKeepsTheirExtras() async throws {
        let db = try makeDatabase()
        let wt = try await makeWorktree(db)
        try await db.worktrees.archive(
            id: wt.id, claudeSessionIDs: ["s1"], claudeSpawnExtras: ["s1": Self.sample])

        try await db.worktrees.revive(id: wt.id, clearSessions: false)
        let revived = try #require(try await db.worktrees.get(id: wt.id))
        #expect(revived.archivedClaudeSpawnExtras == ["s1": Self.sample])
        #expect(revived.archivedClaudeSessions == ["s1"])

        try await db.worktrees.archive(id: wt.id)
        let rearchived = try #require(try await db.worktrees.get(id: wt.id))
        #expect(rearchived.archivedClaudeSpawnExtras == ["s1": Self.sample])
        #expect(rearchived.archivedClaudeSessions == ["s1"])
    }

    /// A new session list replaces the map with it, so no entry from an
    /// earlier archive outlives the list it described.
    @Test func archivingANewSessionListReplacesTheMap() async throws {
        let db = try makeDatabase()
        let wt = try await makeWorktree(db)
        try await db.worktrees.archive(
            id: wt.id, claudeSessionIDs: ["s1"], claudeSpawnExtras: ["s1": Self.sample])
        try await db.worktrees.revive(id: wt.id, clearSessions: false)

        try await db.worktrees.archive(id: wt.id, claudeSessionIDs: ["s2"], claudeSpawnExtras: [:])

        let rearchived = try #require(try await db.worktrees.get(id: wt.id))
        #expect(rearchived.archivedClaudeSessions == ["s2"])
        #expect(rearchived.archivedClaudeSpawnExtras == nil)
    }

    // MARK: - The value

    @Test func nonEmptyNormalizes() {
        #expect(ClaudeSpawnExtras(claudeSettingsOverlay: "  ", pluginDirs: []).nonEmpty == nil)
        #expect(ClaudeSpawnExtras(claudeSettingsOverlay: " \n\t", pluginDirs: nil).nonEmpty == nil)
        #expect(ClaudeSpawnExtras().nonEmpty == nil)

        let overlayOnly = ClaudeSpawnExtras(claudeSettingsOverlay: "{}", pluginDirs: []).nonEmpty
        #expect(overlayOnly?.claudeSettingsOverlay == "{}")
        #expect(overlayOnly != nil && overlayOnly?.pluginDirs == nil)

        let dirsOnly = ClaudeSpawnExtras(claudeSettingsOverlay: "   ", pluginDirs: ["/p"]).nonEmpty
        #expect(dirsOnly == ClaudeSpawnExtras(claudeSettingsOverlay: nil, pluginDirs: ["/p"]))

        // A non-blank overlay is kept verbatim, not trimmed.
        let padded = ClaudeSpawnExtras(claudeSettingsOverlay: " {} ", pluginDirs: ["/p"]).nonEmpty
        #expect(padded == ClaudeSpawnExtras(claudeSettingsOverlay: " {} ", pluginDirs: ["/p"]))
    }

    @Test func jsonKeysAreSpecNames() throws {
        func keys(_ extras: ClaudeSpawnExtras) throws -> [String] {
            let object = try #require(try JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(extras)) as? [String: Any])
            return object.keys.sorted()
        }
        #expect(try keys(Self.sample) == ["claudeSettingsOverlay", "pluginDirs"])
        #expect(try keys(ClaudeSpawnExtras(pluginDirs: ["/p"])) == ["pluginDirs"])
        #expect(try keys(ClaudeSpawnExtras(claudeSettingsOverlay: "{}")) == ["claudeSettingsOverlay"])
        #expect(try keys(ClaudeSpawnExtras()) == [])

        // The column holds the same object.
        let column = try #require(ClaudeSpawnExtrasColumn.encode(ClaudeSpawnExtras(pluginDirs: ["/p"])))
        let stored = try #require(try JSONSerialization.jsonObject(with: Data(column.utf8)) as? [String: Any])
        #expect(stored.keys.sorted() == ["pluginDirs"])
        #expect(stored["pluginDirs"] as? [String] == ["/p"])
    }

    /// Keys a later build adds to the object are ignored, so they can join it
    /// without a migration.
    @Test func unknownKeysAreIgnored() throws {
        let json = #"{"claudeSettingsOverlay":"{}","pluginDirs":["/p"],"later":true}"#
        let decoded = try JSONDecoder().decode(ClaudeSpawnExtras.self, from: Data(json.utf8))
        #expect(decoded == ClaudeSpawnExtras(claudeSettingsOverlay: "{}", pluginDirs: ["/p"]))
    }

    // MARK: - Wire

    /// `Terminal` hand-writes `init(from:)`, so the field must be decoded there
    /// or it would vanish between daemon and app.
    @Test func theTerminalFieldSurvivesTheWire() throws {
        let terminal = Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1", claudeSpawnExtras: Self.sample)
        let decoded = try JSONDecoder().decode(Terminal.self, from: try JSONEncoder().encode(terminal))
        #expect(decoded.claudeSpawnExtras == Self.sample)
    }

    @Test func olderJSONWithoutTheKeysDecodesNil() throws {
        let terminal = Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1", claudeSpawnExtras: Self.sample)
        var terminalObject = try #require(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(terminal)) as? [String: Any])
        terminalObject.removeValue(forKey: "claudeSpawnExtras")
        #expect(try JSONDecoder().decode(
            Terminal.self, from: try JSONSerialization.data(withJSONObject: terminalObject))
            .claudeSpawnExtras == nil)

        let entry = TerminalHistoryEntry(id: UUID(), worktreeID: UUID(), claudeSpawnExtras: Self.sample)
        var entryObject = try #require(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(entry)) as? [String: Any])
        entryObject.removeValue(forKey: "claudeSpawnExtras")
        #expect(try JSONDecoder().decode(
            TerminalHistoryEntry.self, from: try JSONSerialization.data(withJSONObject: entryObject))
            .claudeSpawnExtras == nil)

        let worktree = Worktree(
            repoID: UUID(), name: "n", displayName: "n", branch: "b", path: "/tmp/n",
            tmuxServer: "s", archivedClaudeSpawnExtras: ["s1": Self.sample])
        var worktreeObject = try #require(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(worktree)) as? [String: Any])
        #expect(worktreeObject["archivedClaudeSpawnExtras"] != nil)
        worktreeObject.removeValue(forKey: "archivedClaudeSpawnExtras")
        #expect(try JSONDecoder().decode(
            Worktree.self, from: try JSONSerialization.data(withJSONObject: worktreeObject))
            .archivedClaudeSpawnExtras == nil)
    }
}
