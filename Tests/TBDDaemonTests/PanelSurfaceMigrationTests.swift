import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
import TBDShared

@Suite("PanelSurfaceMigrationTests")
struct PanelSurfaceMigrationTests {

    @Test func v59CreatesTablesAndFlags() async throws {
        let db = try TBDDatabase(inMemory: true)
        let config = try await db.config.get()
        #expect(config.panelSurfaceEnabled == false)
        #expect(config.agentPanelControlEnabled == false)
        try await db.writerForTests.read { dbConn in
            #expect(try dbConn.tableExists("workspace_tab_surface"))
            #expect(try dbConn.tableExists("panel_history"))
            #expect(try dbConn.tableExists("panel_operation_receipt"))
            let cols = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(worktree)")
                .compactMap { $0["name"] as String? }
            #expect(cols.contains("panel_surface_imported_at"))
        }
    }

    @Test func panelSurfaceStoreIsEmptyForFreshWorktree() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v56-\(UUID())", displayName: "v56", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/v56-wt-\(UUID())", tmuxServer: "srv"
        )
        let isEmpty = try await db.panelSurface.isEmpty(worktreeID: wt.id)
        #expect(isEmpty)
    }

    @Test func panelSurfaceImportedAtDefaultsNilAndCanBeStamped() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v56b-\(UUID())", displayName: "v56b", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w2", branch: "b2",
            path: "/tmp/v56-wt2-\(UUID())", tmuxServer: "srv"
        )
        let before = try await db.worktrees.panelSurfaceImportedAt(worktreeID: wt.id)
        #expect(before == nil)

        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try await db.worktrees.stampPanelSurfaceImported(worktreeID: wt.id, at: stamp)
        let after = try await db.worktrees.panelSurfaceImportedAt(worktreeID: wt.id)
        #expect(after == stamp)
    }

    /// Deleting a worktree must cascade-delete its workspace_tab_surface,
    /// panel_history (via tabID → surface → worktree), and
    /// panel_operation_receipt rows — no orphans. Relies on GRDB's
    /// foreign-keys-on default (v55 precedent).
    @Test func deletingWorktreeCascadesPanelSurfaceRows() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v56cascade-\(UUID())", displayName: "v56c", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/v56c-wt-\(UUID())", tmuxServer: "srv")

        let tabID = UUID().uuidString
        let now = Date()
        try await db.writerForTests.write { dbc in
            try dbc.execute(sql: """
                INSERT INTO workspace_tab_surface
                    (id, worktreeID, primaryContent, position, layout, revision, updatedAt)
                VALUES (?, ?, '{}', 0, '{}', 0, ?)
                """, arguments: [tabID, wt.id.uuidString, now])
            try dbc.execute(sql: """
                INSERT INTO panel_history (panelID, tabID, history, updatedAt)
                VALUES (?, ?, '[]', ?)
                """, arguments: [UUID().uuidString, tabID, now])
            try dbc.execute(sql: """
                INSERT INTO panel_operation_receipt
                    (operationID, worktreeID, tabID, revision, result, appliedAt)
                VALUES (?, ?, ?, 0, '{}', ?)
                """, arguments: [UUID().uuidString, wt.id.uuidString, tabID, now])
        }

        try await db.worktrees.delete(id: wt.id)

        try await db.writerForTests.read { dbc in
            let surfaces = try Int.fetchOne(dbc,
                sql: "SELECT COUNT(*) FROM workspace_tab_surface WHERE worktreeID = ?",
                arguments: [wt.id.uuidString])
            let history = try Int.fetchOne(dbc,
                sql: "SELECT COUNT(*) FROM panel_history WHERE tabID = ?",
                arguments: [tabID])
            let receipts = try Int.fetchOne(dbc,
                sql: "SELECT COUNT(*) FROM panel_operation_receipt WHERE worktreeID = ?",
                arguments: [wt.id.uuidString])
            #expect(surfaces == 0)
            #expect(history == 0)
            #expect(receipts == 0)
        }
    }

    /// Seeds a pre-v59 DB (migrated only through v55) with a real repo/worktree
    /// row, then applies the rest (including v59) and confirms the existing row survives untouched
    /// and the new columns/tables show up alongside it — no data loss on
    /// forward migration.
    @Test func forwardMigrationFromPreV59DBPreservesExistingData() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: "v55_oauth_usage_snapshot_cache")

        let repoID = "33333333-3333-3333-3333-333333333333"
        let wtID = "44444444-4444-4444-4444-444444444444"
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                VALUES (?, '/tmp/v56-pre-repo', 'V56', 'main', ?)
                """, arguments: [repoID, Date()])
            try db.execute(sql: """
                INSERT INTO worktree (id, repoID, name, displayName, branch, path, status, createdAt, tmuxServer)
                VALUES (?, ?, 'w', 'w', 'main', '/tmp/v56-pre-wt', 'active', ?, 'tbd-v56')
                """, arguments: [wtID, repoID, Date()])
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let count = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM worktree WHERE id = ?", arguments: [wtID]) ?? -1
            #expect(count == 1, "pre-existing worktree row must survive v59")
            let row = try Row.fetchOne(db, sql: "SELECT * FROM worktree WHERE id = ?", arguments: [wtID])
            #expect(row?["panel_surface_imported_at"] == nil)
            #expect(try db.tableExists("workspace_tab_surface"))
            #expect(try db.tableExists("panel_history"))
            #expect(try db.tableExists("panel_operation_receipt"))
            let configCols = try Row.fetchAll(db, sql: "PRAGMA table_info(config)")
                .compactMap { $0["name"] as String? }
            #expect(configCols.contains("daemon_panel_surface_enabled"))
            #expect(configCols.contains("agent_panel_control_enabled"))
        }
    }
}
