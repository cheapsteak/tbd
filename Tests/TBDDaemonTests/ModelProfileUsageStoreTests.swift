import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("ModelProfileUsageStore")
struct ModelProfileUsageStoreTests {
    @Test func upsertIsIdempotent() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.modelProfiles.create(name: "T", kind: .oauth)
        let u1 = ModelProfileUsage(profileID: tok.id, fiveHourPct: 0.1, sevenDayPct: 0.2, lastStatus: "ok")
        try await db.modelProfileUsage.upsert(u1)
        let u2 = ModelProfileUsage(profileID: tok.id, fiveHourPct: 0.5, sevenDayPct: 0.6, lastStatus: "ok")
        try await db.modelProfileUsage.upsert(u2)

        let fetched = try await db.modelProfileUsage.get(profileID: tok.id)
        #expect(fetched?.fiveHourPct == 0.5)
        #expect(fetched?.sevenDayPct == 0.6)
    }

    @Test func deleteForToken() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.modelProfiles.create(name: "T", kind: .oauth)
        try await db.modelProfileUsage.upsert(ModelProfileUsage(profileID: tok.id, lastStatus: "ok"))
        try await db.modelProfileUsage.deleteForProfile(id: tok.id)
        #expect(try await db.modelProfileUsage.get(profileID: tok.id) == nil)
    }

    @Test func cascadeOnTokenDelete() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.modelProfiles.create(name: "T", kind: .oauth)
        try await db.modelProfileUsage.upsert(ModelProfileUsage(profileID: tok.id, lastStatus: "ok"))
        try await db.modelProfiles.delete(id: tok.id)
        #expect(try await db.modelProfileUsage.get(profileID: tok.id) == nil)
    }
}
