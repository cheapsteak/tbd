import Foundation
import GRDB
import Testing
import DaemonTestSupport

@testable import TBDDaemonLib

/// The landed `20261030194425_panel_tabs` migration
/// (docs/specs/2026-10-30-panel-tabs-design.md, "Rollout").
@Suite("PanelTabsMigration")
struct PanelTabsMigrationTests {

    /// The newest migration identifier before `panel_tabs`. Migrating only
    /// this far reproduces the schema a daemon that predates it ran on.
    private static let lastIdentifierBeforePanelTabs = "20261025182152_config_holder_claim_reconcile"

    /// The v1 panel rows hold the split-tree layout the v2 model cannot read,
    /// so the `panel_tabs` migration deletes every one of them. Rows written
    /// by a daemon that predates the migration are gone afterwards; the
    /// worktree they belonged to is not.
    @Test func migrationEmptiesV1PanelTables() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: Self.lastIdentifierBeforePanelTabs)

        let repoID = "55555555-5555-5555-5555-555555555555"
        let wtID = "66666666-6666-6666-6666-666666666666"
        let tabID = "77777777-7777-7777-7777-777777777777"
        let now = Date()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                VALUES (?, '/tmp/panel-tabs-pre-repo', 'PanelTabs', 'main', ?)
                """, arguments: [repoID, now])
            try db.execute(sql: """
                INSERT INTO worktree (id, repoID, name, displayName, branch, path, status, createdAt, tmuxServer)
                VALUES (?, ?, 'w', 'w', 'main', '/tmp/panel-tabs-pre-wt', 'active', ?, 'tbd-panel-tabs')
                """, arguments: [wtID, repoID, now])
            try db.execute(sql: """
                INSERT INTO workspace_tab_surface
                    (id, worktreeID, primaryContent, position, layout, revision, updatedAt)
                VALUES (?, ?, '{}', 0, '{}', 3, ?)
                """, arguments: [tabID, wtID, now])
            try db.execute(sql: """
                INSERT INTO panel_history (panelID, tabID, history, updatedAt)
                VALUES (?, ?, '[]', ?)
                """, arguments: [UUID().uuidString, tabID, now])
            try db.execute(sql: """
                INSERT INTO panel_operation_receipt
                    (operationID, worktreeID, tabID, revision, result, appliedAt)
                VALUES (?, ?, ?, 3, '{}', ?)
                """, arguments: [UUID().uuidString, wtID, tabID, now])
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let surfaces = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workspace_tab_surface")
            let history = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM panel_history")
            let receipts = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM panel_operation_receipt")
            #expect(surfaces == 0)
            #expect(history == 0)
            #expect(receipts == 0)
            let worktrees = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM worktree WHERE id = ?", arguments: [wtID])
            #expect(worktrees == 1, "the worktree that owned the v1 rows must survive")
            // The daemon-wide revision counter starts at zero, with no row
            // left above it.
            let counter = try Int64.fetchAll(db, sql: "SELECT value FROM panel_revision_counter")
            #expect(counter == [0])
            // The surfaces gain the store-internal marker a scratch promote
            // sets: never NULL, and 0 for a row that awaits no listing.
            let marker = try db.columns(in: "workspace_tab_surface").first { $0.name == "awaitingListing" }
            #expect(marker?.isNotNull == true)
            #expect(marker?.defaultValueSQL == "0")
        }
    }
}
