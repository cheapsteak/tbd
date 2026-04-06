import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Claude Token Migration")
struct ClaudeTokenMigrationTests {
    @Test func v13CreatesClaudeTokensTable() async throws {
        let db = try TBDDatabase(inMemory: true)
        let exists: (Bool, Bool, Bool) = try await db.writerForTests.read { conn in
            (
                try conn.tableExists("claude_tokens"),
                try conn.tableExists("claude_token_usage"),
                try conn.tableExists("config")
            )
        }
        #expect(exists.0)
        #expect(exists.1)
        #expect(exists.2)
    }

    @Test func v13AddsRepoAndTerminalColumns() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cols: ([String], [String]) = try await db.writerForTests.read { conn in
            (
                try conn.columns(in: "repo").map(\.name),
                try conn.columns(in: "terminal").map(\.name)
            )
        }
        #expect(cols.0.contains("claude_token_override_id"))
        #expect(cols.1.contains("claude_token_id"))
    }

    @Test func v13InsertsConfigSingleton() async throws {
        let db = try TBDDatabase(inMemory: true)
        let count: Int? = try await db.writerForTests.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM config WHERE id = 'singleton'")
        }
        #expect(count == 1)
    }
}
