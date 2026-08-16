import Foundation
import GRDB
import os
import TBDShared

private let reapDecodeLogger = Logger(subsystem: "com.tbd.daemon", category: "database.decode")

/// GRDB Record type for the `reap_records` table.
struct ReapRecordRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "reap_records"

    var id: String
    var kind: String
    var repoPath: String
    var worktreePath: String
    var branch: String?
    var headSHA: String?
    var snapshotRef: String?
    var apparentBytes: Int64?
    /// Set by quarantining reaps (`profileDir`) only; NULL for kinds that
    /// delete outright.
    var quarantinePath: String?
    var reapedAt: Date
    var restoredAt: Date?

    init(from record: ReapRecord) {
        self.id = record.id.uuidString
        self.kind = record.kind.rawValue
        self.repoPath = record.repoPath
        self.worktreePath = record.worktreePath
        self.branch = record.branch
        self.headSHA = record.headSHA
        self.snapshotRef = record.snapshotRef
        self.apparentBytes = record.apparentBytes
        self.quarantinePath = record.quarantinePath
        self.reapedAt = record.reapedAt
        self.restoredAt = record.restoredAt
    }

    /// Failable decode: skips (returns nil after a logged warning) rather than
    /// crashing when a required UUID or the reap kind fails to parse.
    /// A single malformed row must not take down the whole `reapRecords.list`
    /// fetch — and thus the daemon — on startup.
    func toModel() -> ReapRecord? {
        guard let uuid = UUID(uuidString: id) else {
            reapDecodeLogger.warning("Skipping reap_records row \(id, privacy: .public): malformed id")
            return nil
        }
        guard let reapKind = ReapKind(rawValue: kind) else {
            reapDecodeLogger.warning("Skipping reap_records row \(id, privacy: .public): unknown kind \(kind, privacy: .public)")
            return nil
        }
        return ReapRecord(
            id: uuid,
            kind: reapKind,
            repoPath: repoPath,
            worktreePath: worktreePath,
            branch: branch,
            headSHA: headSHA,
            snapshotRef: snapshotRef,
            apparentBytes: apparentBytes,
            quarantinePath: quarantinePath,
            reapedAt: reapedAt,
            restoredAt: restoredAt
        )
    }
}

/// Provides CRUD operations for orphan-GC reap records.
public struct ReapRecordStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Persist a new reap record.
    public func insert(_ record: ReapRecord) async throws {
        let dbRecord = ReapRecordRecord(from: record)
        try await writer.write { db in
            try dbRecord.insert(db)
        }
    }

    /// All reap records, newest first. `repoPath` nil returns every repo.
    public func list(repoPath: String?) async throws -> [ReapRecord] {
        try await writer.read { db in
            var request = ReapRecordRecord.order(Column("reapedAt").desc)
            if let repoPath {
                request = request.filter(Column("repoPath") == repoPath)
            }
            return try request.fetchAll(db).compactMap { $0.toModel() }
        }
    }

    /// Fetch a single reap record by id.
    public func get(id: UUID) async throws -> ReapRecord? {
        try await writer.read { db in
            try ReapRecordRecord.fetchOne(db, key: id.uuidString)?.toModel()
        }
    }

    /// Mark a reap record as restored at the given date.
    public func markRestored(id: UUID, at date: Date) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE reap_records SET restoredAt = ? WHERE id = ?",
                arguments: [date, id.uuidString]
            )
        }
    }

    /// Reap records that are still un-restored, were reaped before `date`,
    /// and captured a snapshot ref — the candidate set for snapshot-retention
    /// GC (expired-snapshot pruning).
    public func unrestoredOlderThan(_ date: Date) async throws -> [ReapRecord] {
        try await writer.read { db in
            try ReapRecordRecord
                .filter(Column("restoredAt") == nil)
                .filter(Column("reapedAt") < date)
                .filter(Column("snapshotRef") != nil)
                .order(Column("reapedAt").desc)
                .fetchAll(db)
                .compactMap { $0.toModel() }
        }
    }
}
