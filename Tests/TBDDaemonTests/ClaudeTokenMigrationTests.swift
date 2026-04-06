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

    @Test func migrationPreservesExistingRowsAndAddsColumns() async throws {
        let tmp = NSTemporaryDirectory() + "tbd-mig-test-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        do {
            let db = try TBDDatabase(path: tmp)
            let repo = try await db.repos.create(path: "/tmp/x", displayName: "x", defaultBranch: "main")
            let wt = try await db.worktrees.create(
                repoID: repo.id, name: "w", branch: "tbd/w",
                path: "/tmp/x/.tbd/worktrees/w", tmuxServer: "tbd-test"
            )
            _ = try await db.terminals.create(
                worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%0", label: "claude"
            )
        }

        let db2 = try TBDDatabase(path: tmp)
        let repos = try await db2.repos.list()
        #expect(repos.count == 1)
        #expect(repos[0].claudeTokenOverrideID == nil)
        let terms = try await db2.terminals.list()
        #expect(terms.count == 1)
        #expect(terms[0].claudeTokenID == nil)
        let cfg = try await db2.config.get()
        #expect(cfg.defaultClaudeTokenID == nil)
    }

    @Test func v13InsertsConfigSingleton() async throws {
        let db = try TBDDatabase(inMemory: true)
        let count: Int? = try await db.writerForTests.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM config WHERE id = 'singleton'")
        }
        #expect(count == 1)
    }
}
