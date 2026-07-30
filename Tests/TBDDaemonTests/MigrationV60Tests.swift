import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1. `v60_drop_nightwatch_merge_gate_tables` removes the two tables that
/// backed the deleted compiled merge gate. v41/v42 still create them (migration
/// history is append-only), so a freshly migrated DB must show them created and
/// then dropped again.
@Suite struct MigrationV60Tests {

    @Test func clearanceTableIsDropped() async throws {
        let db = try TBDDatabase(inMemory: true)
        let exists = try await db.writerForTests.read { dbConn in
            try dbConn.tableExists("clearance")
        }
        #expect(!exists, "v60 should drop the clearance table created in v41_clearance_ledger")
    }

    @Test func auditLogTableIsDropped() async throws {
        let db = try TBDDatabase(inMemory: true)
        let exists = try await db.writerForTests.read { dbConn in
            try dbConn.tableExists("audit_log")
        }
        #expect(!exists, "v60 should drop the audit_log table created in v42_audit_log")
    }

    /// Dropping a table drops its indexes too — assert it, so a future
    /// re-registration of these tables can't silently collide on the index name.
    @Test func mergeGateIndexesAreGone() async throws {
        let db = try TBDDatabase(inMemory: true)
        let names = try await db.writerForTests.read { dbConn in
            try String.fetchSet(dbConn, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        #expect(!names.contains("idx_clearance_pr_repo"))
        #expect(!names.contains("idx_audit_log_ts"))
    }

    /// Guard the surgical scope: the sibling nightwatch DESK feature (System B)
    /// keeps its `config.nightwatch_mode` column from v38.
    @Test func nightwatchModeColumnSurvives() async throws {
        let db = try TBDDatabase(inMemory: true)
        let columns = try await db.writerForTests.read { dbConn in
            try dbConn.columns(in: "config").map(\.name)
        }
        #expect(columns.contains("nightwatch_mode"))
    }
}
