import Foundation
import GRDB
import TBDShared

struct ModelProfileUsageRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "model_profile_usage"

    var profile_id: String
    var five_hour_pct: Double?
    var seven_day_pct: Double?
    var five_hour_resets_at: Date?
    var seven_day_resets_at: Date?
    var fetched_at: Date?
    var last_status: String?

    init(from u: ModelProfileUsage) {
        self.profile_id = u.profileID.uuidString
        self.five_hour_pct = u.fiveHourPct
        self.seven_day_pct = u.sevenDayPct
        self.five_hour_resets_at = u.fiveHourResetsAt
        self.seven_day_resets_at = u.sevenDayResetsAt
        self.fetched_at = u.fetchedAt
        self.last_status = u.lastStatus
    }

    func toModel() -> ModelProfileUsage {
        ModelProfileUsage(
            profileID: UUID(uuidString: profile_id)!,
            fiveHourPct: five_hour_pct,
            sevenDayPct: seven_day_pct,
            fiveHourResetsAt: five_hour_resets_at,
            sevenDayResetsAt: seven_day_resets_at,
            fetchedAt: fetched_at,
            lastStatus: last_status
        )
    }
}

public struct ModelProfileUsageStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func upsert(_ usage: ModelProfileUsage) async throws {
        let record = ModelProfileUsageRecord(from: usage)
        try await writer.write { db in
            try record.save(db)
        }
    }

    public func get(profileID: UUID) async throws -> ModelProfileUsage? {
        try await writer.read { db in
            try ModelProfileUsageRecord.fetchOne(db, key: profileID.uuidString)?.toModel()
        }
    }

    public func fetchAll() async throws -> [UUID: ModelProfileUsage] {
        try await writer.read { db in
            let records = try ModelProfileUsageRecord.fetchAll(db)
            var byProfileID: [UUID: ModelProfileUsage] = [:]
            byProfileID.reserveCapacity(records.count)
            for record in records {
                let usage = record.toModel()
                byProfileID[usage.profileID] = usage
            }
            return byProfileID
        }
    }

    public func deleteForProfile(id: UUID) async throws {
        _ = try await writer.write { db in
            try ModelProfileUsageRecord.deleteOne(db, key: id.uuidString)
        }
    }
}
