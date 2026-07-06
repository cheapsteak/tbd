import Foundation
import GRDB
import TBDShared

/// GRDB Record type for the `clearance` table.
struct ClearanceRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "clearance"

    var id: String
    var pr_number: Int
    var repo: String
    var cleared_when_sha: String
    var pr_state_at_clear: String?
    var clearance_kind: String
    var granted_by: String?
    var granted_at: Date
    var void_reason: String?

    init(from clearance: Clearance) {
        self.id = clearance.id
        self.pr_number = clearance.prNumber
        self.repo = clearance.repo
        self.cleared_when_sha = clearance.clearedWhenSHA
        self.pr_state_at_clear = clearance.prStateAtClear
        self.clearance_kind = clearance.clearanceKind.rawValue
        self.granted_by = clearance.grantedBy
        self.granted_at = clearance.grantedAt
        self.void_reason = clearance.voidReason
    }

    func toModel() -> Clearance {
        Clearance(
            id: id,
            prNumber: pr_number,
            repo: repo,
            clearedWhenSHA: cleared_when_sha,
            prStateAtClear: pr_state_at_clear,
            clearanceKind: ClearanceKind(rawValue: clearance_kind) ?? .small_safe,
            grantedBy: granted_by,
            grantedAt: granted_at,
            voidReason: void_reason
        )
    }
}

/// Provides CRUD operations for clearance records.
public struct ClearanceStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Insert a new clearance record.
    public func insert(_ clearance: Clearance) async throws {
        try await writer.write { db in
            let record = ClearanceRecord(from: clearance)
            try record.insert(db)
        }
    }

    /// Void a clearance by ID with a reason.
    public func voidByID(_ id: String, reason: String) async throws {
        try await writer.write { db in
            guard var record = try ClearanceRecord.fetchOne(db, key: id) else {
                throw DatabaseError(message: "Clearance not found")
            }
            record.void_reason = reason
            try record.update(db)
        }
    }

    /// Void every live clearance for the PR that is pinned to a SHA other
    /// than `newSHA` — a clearance granted on the current head stays valid.
    public func voidBySHA(pr: Int, repo: String, newSHA: String, reason: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                UPDATE clearance
                SET void_reason = ?
                WHERE pr_number = ? AND repo = ? AND void_reason IS NULL
                  AND cleared_when_sha != ?
                """,
                arguments: [reason, pr, repo, newSHA]
            )
        }
    }

    /// List clearances for a specific PR.
    public func listByPR(_ prNumber: Int, repo: String) async throws -> [Clearance] {
        try await writer.read { db in
            let records = try ClearanceRecord
                .filter(Column("pr_number") == prNumber && Column("repo") == repo)
                .fetchAll(db)
            return records.map { $0.toModel() }
        }
    }

    /// Get audit trail of clearances (all non-void clearances).
    public func auditTrail(since: Date? = nil) async throws -> [Clearance] {
        try await writer.read { db in
            var request = ClearanceRecord.filter(Column("void_reason") == nil)
            if let since {
                request = request.filter(Column("granted_at") >= since)
            }
            let records = try request.order(Column("granted_at")).fetchAll(db)
            return records.map { $0.toModel() }
        }
    }

    /// Get a clearance by ID.
    public func get(id: String) async throws -> Clearance? {
        try await writer.read { db in
            try ClearanceRecord.fetchOne(db, key: id)?.toModel()
        }
    }
}
