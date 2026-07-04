import Foundation
import GRDB
import TBDShared

/// GRDB Record for the `scheduled_resumes` table.
struct ScheduledResumeRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "scheduled_resumes"

    var id: String
    var terminalID: String
    var worktreeID: String
    var claudeSessionID: String?
    var resetsAt: Date
    var fireAt: Date
    var limitType: String
    var rawMessage: String
    var createdAt: Date
    var status: String
    var attemptCount: Int

    init(from model: ScheduledResume) {
        self.id = model.id.uuidString
        self.terminalID = model.terminalID.uuidString
        self.worktreeID = model.worktreeID.uuidString
        self.claudeSessionID = model.claudeSessionID
        self.resetsAt = model.resetsAt
        self.fireAt = model.fireAt
        self.limitType = model.limitType
        self.rawMessage = model.rawMessage
        self.createdAt = model.createdAt
        self.status = model.status.rawValue
        self.attemptCount = model.attemptCount
    }

    func toModel() -> ScheduledResume {
        ScheduledResume(
            id: UUID(uuidString: id)!,
            terminalID: UUID(uuidString: terminalID)!,
            worktreeID: UUID(uuidString: worktreeID)!,
            claudeSessionID: claudeSessionID,
            resetsAt: resetsAt,
            fireAt: fireAt,
            limitType: limitType,
            rawMessage: rawMessage,
            createdAt: createdAt,
            status: ScheduledResumeStatus(rawValue: status) ?? .failed,
            attemptCount: attemptCount
        )
    }
}

/// CRUD for scheduled session-limit resumes. The single `pending` row per
/// terminal is the double-send latch (spec §State); every transition that
/// creates/moves/ends a pending row also syncs `terminal.pendingResumeAt`
/// inside the SAME write transaction so the UI mirror can never drift.
public struct ScheduledResumeStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Insert a pending row unless the terminal already has one.
    /// - Returns: the inserted model, or nil when the latch rejected it.
    public func insertPending(_ resume: ScheduledResume) async throws -> ScheduledResume? {
        var toInsert = resume
        toInsert.status = .pending
        let record = ScheduledResumeRecord(from: toInsert)
        let resultModel = toInsert
        return try await writer.write { db -> ScheduledResume? in
            let existing = try ScheduledResumeRecord
                .filter(Column("terminalID") == record.terminalID)
                .filter(Column("status") == ScheduledResumeStatus.pending.rawValue)
                .fetchCount(db)
            guard existing == 0 else { return nil }
            try record.insert(db)
            try db.execute(
                sql: "UPDATE terminal SET pendingResumeAt = ? WHERE id = ?",
                arguments: [record.fireAt, record.terminalID])
            return resultModel
        }
    }

    /// Insert a non-pending audit row (e.g. toggle-off detection: `.cancelled`).
    /// Never touches the latch or `terminal.pendingResumeAt`.
    public func insertAudit(_ resume: ScheduledResume) async throws {
        precondition(resume.status != .pending, "audit rows must not be pending")
        let record = ScheduledResumeRecord(from: resume)
        try await writer.write { db in
            try record.insert(db)
        }
    }

    /// All pending rows ordered by fireAt ascending.
    public func pending() async throws -> [ScheduledResume] {
        try await writer.read { db in
            try ScheduledResumeRecord
                .filter(Column("status") == ScheduledResumeStatus.pending.rawValue)
                .order(Column("fireAt").asc)
                .fetchAll(db)
                .map { $0.toModel() }
        }
    }

    public func pending(terminalID: UUID) async throws -> ScheduledResume? {
        try await writer.read { db in
            try ScheduledResumeRecord
                .filter(Column("terminalID") == terminalID.uuidString)
                .filter(Column("status") == ScheduledResumeStatus.pending.rawValue)
                .fetchOne(db)?
                .toModel()
        }
    }

    public func get(id: UUID) async throws -> ScheduledResume? {
        try await writer.read { db in
            try ScheduledResumeRecord.fetchOne(db, key: id.uuidString)?.toModel()
        }
    }

    /// Transition a row's status. Leaving `.pending` clears the terminal's
    /// `pendingResumeAt` mirror.
    public func setStatus(id: UUID, status: ScheduledResumeStatus) async throws {
        try await writer.write { db in
            guard var record = try ScheduledResumeRecord.fetchOne(db, key: id.uuidString) else {
                return
            }
            record.status = status.rawValue
            try record.update(db)
            if status != .pending {
                try db.execute(
                    sql: "UPDATE terminal SET pendingResumeAt = NULL WHERE id = ?",
                    arguments: [record.terminalID])
            }
        }
    }

    /// Push a pending row's fire time (copy-mode retry) and bump attemptCount.
    public func reschedule(id: UUID, fireAt: Date, attemptCount: Int) async throws {
        try await writer.write { db in
            guard var record = try ScheduledResumeRecord.fetchOne(db, key: id.uuidString) else {
                return
            }
            record.fireAt = fireAt
            record.attemptCount = attemptCount
            try record.update(db)
            try db.execute(
                sql: "UPDATE terminal SET pendingResumeAt = ? WHERE id = ?",
                arguments: [fireAt, record.terminalID])
        }
    }

    /// Cancel the terminal's pending row, if any. Returns true when one existed.
    @discardableResult
    public func cancelPending(terminalID: UUID) async throws -> Bool {
        try await writer.write { db in
            guard var record = try ScheduledResumeRecord
                .filter(Column("terminalID") == terminalID.uuidString)
                .filter(Column("status") == ScheduledResumeStatus.pending.rawValue)
                .fetchOne(db)
            else { return false }
            record.status = ScheduledResumeStatus.cancelled.rawValue
            try record.update(db)
            try db.execute(
                sql: "UPDATE terminal SET pendingResumeAt = NULL WHERE id = ?",
                arguments: [terminalID.uuidString])
            return true
        }
    }

    /// Cancel every pending row (global toggle switched off). Returns count.
    @discardableResult
    public func cancelAllPending() async throws -> Int {
        try await writer.write { db in
            let records = try ScheduledResumeRecord
                .filter(Column("status") == ScheduledResumeStatus.pending.rawValue)
                .fetchAll(db)
            for var record in records {
                record.status = ScheduledResumeStatus.cancelled.rawValue
                try record.update(db)
                try db.execute(
                    sql: "UPDATE terminal SET pendingResumeAt = NULL WHERE id = ?",
                    arguments: [record.terminalID])
            }
            return records.count
        }
    }
}
