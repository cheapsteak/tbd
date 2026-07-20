import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// DB-level coverage for the OAuth usage snapshot cache (migration
/// `v55_oauth_usage_snapshot_cache`): the JSON blob round-trips the shared
/// `ProfileUsageSnapshot` model exactly, replaces on upsert, cascades on
/// profile delete, and tolerates malformed rows.
@Suite("OAuthUsageSnapshotStore")
struct OAuthUsageSnapshotStoreTests {

    private let buckets = [
        ClaudeUsageLimitBucket(kind: "session", group: "session", percent: 42,
                               resetsAt: Date(timeIntervalSince1970: 1_800_000_000)),
        ClaudeUsageLimitBucket(kind: "weekly_all", group: "weekly", percent: 7),
    ]

    private func snapshot(fetchedAt: Date) -> ProfileUsageSnapshot {
        ProfileUsageSnapshot(buckets: buckets, fetchedAt: fetchedAt,
                             lastAttemptAt: fetchedAt, status: "ok", statusKind: .ok)
    }

    @Test func upsertRoundTripsExactSnapshot() async throws {
        let db = try TBDDatabase(inMemory: true)
        let profile = try await db.modelProfiles.create(name: "P", kind: .oauth)
        // Fractional seconds: fetchedAt must survive exactly so staleness
        // stays computable after a daemon restart.
        let snap = snapshot(fetchedAt: Date(timeIntervalSince1970: 1_750_000_000.25))

        try await db.oauthUsageSnapshots.upsert(profileID: profile.id, snapshot: snap)

        let all = try await db.oauthUsageSnapshots.loadAll()
        #expect(all == [profile.id: snap])
    }

    @Test func upsertReplacesExistingRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let profile = try await db.modelProfiles.create(name: "P", kind: .oauth)
        try await db.oauthUsageSnapshots.upsert(
            profileID: profile.id, snapshot: snapshot(fetchedAt: Date(timeIntervalSince1970: 1)))
        let newer = snapshot(fetchedAt: Date(timeIntervalSince1970: 2))
        try await db.oauthUsageSnapshots.upsert(profileID: profile.id, snapshot: newer)

        let all = try await db.oauthUsageSnapshots.loadAll()
        #expect(all.count == 1)
        #expect(all[profile.id] == newer)
    }

    @Test func profileDeleteCascades() async throws {
        let db = try TBDDatabase(inMemory: true)
        let profile = try await db.modelProfiles.create(name: "P", kind: .oauth)
        try await db.oauthUsageSnapshots.upsert(
            profileID: profile.id, snapshot: snapshot(fetchedAt: Date(timeIntervalSince1970: 1)))

        try await db.modelProfiles.delete(id: profile.id)

        let all = try await db.oauthUsageSnapshots.loadAll()
        #expect(all.isEmpty)
    }

    @Test func malformedRowIsSkippedNotThrown() async throws {
        let db = try TBDDatabase(inMemory: true)
        let good = try await db.modelProfiles.create(name: "G", kind: .oauth)
        let bad = try await db.modelProfiles.create(name: "B", kind: .oauth)
        let snap = snapshot(fetchedAt: Date(timeIntervalSince1970: 1))
        try await db.oauthUsageSnapshots.upsert(profileID: good.id, snapshot: snap)
        try await db.writerForTests.write { sqlDb in
            try sqlDb.execute(
                sql: "INSERT INTO oauth_profile_usage_snapshot (profile_id, snapshot_json) VALUES (?, ?)",
                arguments: [bad.id.uuidString, "not json"]
            )
        }

        let all = try await db.oauthUsageSnapshots.loadAll()
        #expect(all == [good.id: snap])
    }

    @Test func deleteExceptRemovesOnlyRowsOutsideTheKeepSet() async throws {
        let db = try TBDDatabase(inMemory: true)
        let keep = try await db.modelProfiles.create(name: "Keep", kind: .oauth)
        let drop = try await db.modelProfiles.create(name: "Drop", kind: .oauth)
        let snap = snapshot(fetchedAt: Date(timeIntervalSince1970: 1))
        try await db.oauthUsageSnapshots.upsert(profileID: keep.id, snapshot: snap)
        try await db.oauthUsageSnapshots.upsert(profileID: drop.id, snapshot: snap)

        try await db.oauthUsageSnapshots.deleteExcept(profileIDs: [keep.id])

        let all = try await db.oauthUsageSnapshots.loadAll()
        #expect(all == [keep.id: snap])
    }
}
