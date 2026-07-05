import Foundation
import Testing
@testable import TBDDaemonLib
import GRDB
import TBDShared

@Suite("Nightwatch Migrations")
struct MigrationTests_Nightwatch {

    @Test("v39_clearance migration creates table with correct schema")
    func v39ClearanceSchema() throws {
        let db = try TBDDatabase(inMemory: true)

        // Verify table exists
        let tableExists = try db.writerForTests.read { db in
            try db.tableExists("clearance")
        }
        #expect(tableExists, "clearance table should exist after migration")

        // Verify columns exist
        let columns = try db.writerForTests.read { db in
            try db.columns(in: "clearance")
        }
        let columnNames = Set(columns.map { $0.name })

        #expect(columnNames.contains("id"))
        #expect(columnNames.contains("pr_number"))
        #expect(columnNames.contains("repo"))
        #expect(columnNames.contains("cleared_when_sha"))
        #expect(columnNames.contains("pr_state_at_clear"))
        #expect(columnNames.contains("clearance_kind"))
        #expect(columnNames.contains("granted_by"))
        #expect(columnNames.contains("granted_at"))
        #expect(columnNames.contains("void_reason"))
    }

    @Test("v42_audit_log migration creates table with correct schema")
    func v40AuditLogSchema() throws {
        let db = try TBDDatabase(inMemory: true)

        // Verify table exists
        let tableExists = try db.writerForTests.read { db in
            try db.tableExists("audit_log")
        }
        #expect(tableExists, "audit_log table should exist after migration")

        // Verify columns exist
        let columns = try db.writerForTests.read { db in
            try db.columns(in: "audit_log")
        }
        let columnNames = Set(columns.map { $0.name })

        #expect(columnNames.contains("id"))
        #expect(columnNames.contains("action"))
        #expect(columnNames.contains("pr_number"))
        #expect(columnNames.contains("repo"))
        #expect(columnNames.contains("head_sha"))
        #expect(columnNames.contains("merge_commit"))
        #expect(columnNames.contains("ts"))
        #expect(columnNames.contains("details"))
    }

    @Test("Clearance table has correct primary key")
    func clearancePrimaryKey() async throws {
        let db = try TBDDatabase(inMemory: true)

        // Insert a record
        let clearance = Clearance(
            id: "test-id",
            prNumber: 1,
            repo: "test/repo",
            clearedWhenSHA: "abc123",
            clearanceKind: .small_safe
        )
        try await db.clearance.insert(clearance)

        // Attempt to insert duplicate - should fail due to PK constraint
        let duplicate = Clearance(
            id: "test-id",
            prNumber: 2,
            repo: "test/repo",
            clearedWhenSHA: "def456",
            clearanceKind: .preclear
        )

        var threwError = false
        do {
            try await db.clearance.insert(duplicate)
        } catch {
            threwError = true
        }
        #expect(threwError, "Inserting duplicate ID should fail")
    }

    @Test("Audit log table allows multiple entries")
    func auditLogAllowsMultiple() async throws {
        let db = try TBDDatabase(inMemory: true)

        try await db.audit.logAction(AuditLogEntry(action: .wouldMerge, prNumber: 1))
        try await db.audit.logAction(AuditLogEntry(action: .hold, prNumber: 2))
        try await db.audit.logAction(AuditLogEntry(action: .escalate, prNumber: 3))

        let entries = try await db.audit.list()
        #expect(entries.count == 3)
    }
}
