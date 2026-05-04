import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

/// Tests for the cumulative effect of v13 (which originally created
/// `claude_tokens`) plus v15 (which renames it to `model_profiles`).
/// In a fresh DB both migrations run together, so post-migration assertions
/// reflect the v15 state.
@Suite("Migration: v13 + v15 combined")
struct ModelProfileV13MigrationTests {
    @Test func tablesExistAfterAllMigrations() async throws {
        let db = try TBDDatabase(inMemory: true)
        let exists: (Bool, Bool, Bool, Bool) = try await db.writerForTests.read { conn in
            (
                try conn.tableExists("model_profiles"),
                try conn.tableExists("model_profile_usage"),
                try conn.tableExists("config"),
                try conn.tableExists("claude_tokens")
            )
        }
        #expect(exists.0)
        #expect(exists.1)
        #expect(exists.2)
        #expect(exists.3 == false, "v15 should have renamed claude_tokens away")
    }

    @Test func repoAndTerminalColumnsAreRenamed() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cols: ([String], [String]) = try await db.writerForTests.read { conn in
            (
                try conn.columns(in: "repo").map(\.name),
                try conn.columns(in: "terminal").map(\.name)
            )
        }
        #expect(cols.0.contains("profile_override_id"))
        #expect(!cols.0.contains("claude_token_override_id"))
        #expect(cols.1.contains("profile_id"))
        #expect(!cols.1.contains("claude_token_id"))
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
        #expect(repos[0].profileOverrideID == nil)
        let terms = try await db2.terminals.list()
        #expect(terms.count == 1)
        #expect(terms[0].profileID == nil)
        let cfg = try await db2.config.get()
        #expect(cfg.defaultProfileID == nil)
    }

    @Test func configSingletonExistsAfterMigrations() async throws {
        let db = try TBDDatabase(inMemory: true)
        let count: Int? = try await db.writerForTests.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM config WHERE id = 'singleton'")
        }
        #expect(count == 1)
    }
}
