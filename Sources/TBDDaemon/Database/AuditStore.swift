import Foundation
import GRDB
import os
import TBDShared

/// GRDB Record type for the `audit_log` table.
struct AuditLogRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "audit_log"

    var id: String
    var action: String
    var pr_number: Int?
    var repo: String?
    var head_sha: String?
    var merge_commit: String?
    var ts: Date
    var details: String?

    init(from entry: AuditLogEntry) {
        self.id = entry.id
        self.action = entry.action.rawValue
        self.pr_number = entry.prNumber
        self.repo = entry.repo
        self.head_sha = entry.headSHA
        self.merge_commit = entry.mergeCommit
        self.ts = entry.timestamp
        self.details = entry.details
    }

    func toModel() -> AuditLogEntry {
        AuditLogEntry(
            id: id,
            action: AuditAction(rawValue: action) ?? .escalate,
            prNumber: pr_number,
            repo: repo,
            headSHA: head_sha,
            mergeCommit: merge_commit,
            timestamp: ts,
            details: details
        )
    }
}

/// Provides operations for audit logging.
public struct AuditStore: Sendable {
    let writer: any DatabaseWriter
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "nightwatch.audit")

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Log an action to the audit trail.
    public func logAction(_ entry: AuditLogEntry) async throws {
        try await writer.write { db in
            let record = AuditLogRecord(from: entry)
            try record.insert(db)
        }
        // Mirror to os.Logger for incident investigation
        Self.logger.debug(
            """
            action=\(entry.action.rawValue, privacy: .public) \
            pr=\(entry.prNumber?.description ?? "N/A", privacy: .public) \
            repo=\(entry.repo ?? "N/A", privacy: .public) \
            sha=\(entry.headSHA?.prefix(8) ?? "N/A", privacy: .public)
            """
        )
    }

    /// List audit log entries within a time window, optionally filtered by action.
    public func list(since: Date? = nil, until: Date? = nil, action: AuditAction? = nil) async throws -> [AuditLogEntry] {
        try await writer.read { db in
            var request = AuditLogRecord.all()
            if let since {
                request = request.filter(Column("ts") >= since)
            }
            if let until {
                request = request.filter(Column("ts") <= until)
            }
            if let action {
                request = request.filter(Column("action") == action.rawValue)
            }
            let records = try request.order(Column("ts").desc).fetchAll(db)
            return records.map { $0.toModel() }
        }
    }

    /// Get a specific audit log entry by ID.
    public func get(id: String) async throws -> AuditLogEntry? {
        try await writer.read { db in
            try AuditLogRecord.fetchOne(db, key: id)?.toModel()
        }
    }

    /// Count audit entries by action in a time window.
    public func countByAction(since: Date? = nil, until: Date? = nil) async throws -> [AuditAction: Int] {
        try await writer.read { db in
            var request = AuditLogRecord.all()
            if let since {
                request = request.filter(Column("ts") >= since)
            }
            if let until {
                request = request.filter(Column("ts") <= until)
            }
            let records = try request.fetchAll(db)
            var counts: [AuditAction: Int] = [:]
            for record in records {
                if let action = AuditAction(rawValue: record.action) {
                    counts[action, default: 0] += 1
                }
            }
            return counts
        }
    }
}
