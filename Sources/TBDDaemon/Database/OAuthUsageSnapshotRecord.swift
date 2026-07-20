import Foundation
import GRDB
import os
import TBDShared

private let decodeLogger = Logger(subsystem: "com.tbd.daemon", category: "database.decode")

/// Last-known OAuth usage snapshot per profile, persisted as a JSON blob of
/// the shared `ProfileUsageSnapshot` model (which carries its own `fetchedAt`,
/// so staleness stays computable after a reload). Daemon-internal cache state
/// — not user-authored config — so it lives in the DB, and rows regenerate on
/// the next successful fetch. Profile deletion cascades via the FK.
struct OAuthUsageSnapshotRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "oauth_profile_usage_snapshot"

    var profile_id: String
    var snapshot_json: String
}

public struct OAuthUsageSnapshotStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func upsert(profileID: UUID, snapshot: ProfileUsageSnapshot) async throws {
        // Default (deferredToDate) date strategy: doubles round-trip exactly.
        let data = try JSONEncoder().encode(snapshot)
        guard let json = String(bytes: data, encoding: .utf8) else {
            // Unreachable in practice — JSONEncoder emits UTF-8 — but the
            // store must never write a blob it can't read back.
            return
        }
        let record = OAuthUsageSnapshotRecord(
            profile_id: profileID.uuidString,
            snapshot_json: json
        )
        try await writer.write { db in
            try record.save(db)
        }
    }

    /// Delete rows for every profile NOT in `profileIDs`. Full sweeps call
    /// this so snapshots for deleted or logged-out profiles don't reload as
    /// ghosts on the next daemon restart.
    public func deleteExcept(profileIDs: Set<UUID>) async throws {
        let keep = profileIDs.map(\.uuidString)
        try await writer.write { db in
            _ = try OAuthUsageSnapshotRecord
                .filter(!keep.contains(Column("profile_id")))
                .deleteAll(db)
        }
    }

    /// All persisted snapshots keyed by profile ID. Malformed rows (bad UUID
    /// or undecodable JSON) are skipped with a logged warning, never thrown —
    /// this is a cache, and the poller refills it.
    public func loadAll() async throws -> [UUID: ProfileUsageSnapshot] {
        try await writer.read { db in
            let records = try OAuthUsageSnapshotRecord.fetchAll(db)
            var byProfileID: [UUID: ProfileUsageSnapshot] = [:]
            byProfileID.reserveCapacity(records.count)
            for record in records {
                guard let uuid = UUID(uuidString: record.profile_id),
                      let snapshot = try? JSONDecoder().decode(
                        ProfileUsageSnapshot.self, from: Data(record.snapshot_json.utf8))
                else {
                    decodeLogger.warning("Skipping oauth_profile_usage_snapshot row: malformed \(record.profile_id, privacy: .public)")
                    continue
                }
                byProfileID[uuid] = snapshot
            }
            return byProfileID
        }
    }
}
