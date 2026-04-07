import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("ClaudeTokenUsageStore")
struct ClaudeTokenUsageStoreTests {
    @Test func upsertIsIdempotent() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.claudeTokens.create(name: "T", kind: .oauth)
        let u1 = ClaudeTokenUsage(tokenID: tok.id, fiveHourPct: 0.1, sevenDayPct: 0.2, lastStatus: "ok")
        try await db.claudeTokenUsage.upsert(u1)
        let u2 = ClaudeTokenUsage(tokenID: tok.id, fiveHourPct: 0.5, sevenDayPct: 0.6, lastStatus: "ok")
        try await db.claudeTokenUsage.upsert(u2)

        let fetched = try await db.claudeTokenUsage.get(tokenID: tok.id)
        #expect(fetched?.fiveHourPct == 0.5)
        #expect(fetched?.sevenDayPct == 0.6)
    }

    @Test func deleteForToken() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.claudeTokens.create(name: "T", kind: .oauth)
        try await db.claudeTokenUsage.upsert(ClaudeTokenUsage(tokenID: tok.id, lastStatus: "ok"))
        try await db.claudeTokenUsage.deleteForToken(id: tok.id)
        #expect(try await db.claudeTokenUsage.get(tokenID: tok.id) == nil)
    }

    @Test func cascadeOnTokenDelete() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.claudeTokens.create(name: "T", kind: .oauth)
        try await db.claudeTokenUsage.upsert(ClaudeTokenUsage(tokenID: tok.id, lastStatus: "ok"))
        try await db.claudeTokens.delete(id: tok.id)
        #expect(try await db.claudeTokenUsage.get(tokenID: tok.id) == nil)
    }
}
