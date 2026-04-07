import Foundation
import GRDB
import TBDShared

struct ClaudeTokenUsageRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "claude_token_usage"

    var token_id: String
    var five_hour_pct: Double?
    var seven_day_pct: Double?
    var five_hour_resets_at: Date?
    var seven_day_resets_at: Date?
    var fetched_at: Date?
    var last_status: String?

    init(from u: ClaudeTokenUsage) {
        self.token_id = u.tokenID.uuidString
        self.five_hour_pct = u.fiveHourPct
        self.seven_day_pct = u.sevenDayPct
        self.five_hour_resets_at = u.fiveHourResetsAt
        self.seven_day_resets_at = u.sevenDayResetsAt
        self.fetched_at = u.fetchedAt
        self.last_status = u.lastStatus
    }

    func toModel() -> ClaudeTokenUsage {
        ClaudeTokenUsage(
            tokenID: UUID(uuidString: token_id)!,
            fiveHourPct: five_hour_pct,
            sevenDayPct: seven_day_pct,
            fiveHourResetsAt: five_hour_resets_at,
            sevenDayResetsAt: seven_day_resets_at,
            fetchedAt: fetched_at,
            lastStatus: last_status
        )
    }
}

public struct ClaudeTokenUsageStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func upsert(_ usage: ClaudeTokenUsage) async throws {
        let record = ClaudeTokenUsageRecord(from: usage)
        try await writer.write { db in
            try record.save(db)
        }
    }

    public func get(tokenID: UUID) async throws -> ClaudeTokenUsage? {
        try await writer.read { db in
            try ClaudeTokenUsageRecord.fetchOne(db, key: tokenID.uuidString)?.toModel()
        }
    }

    public func deleteForToken(id: UUID) async throws {
        _ = try await writer.write { db in
            try ClaudeTokenUsageRecord.deleteOne(db, key: id.uuidString)
        }
    }
}
