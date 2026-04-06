import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("ClaudeTokenStore")
struct ClaudeTokenStoreTests {
    @Test func createListGet() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.claudeTokens.create(name: "Personal", kind: .oauth)
        #expect(tok.name == "Personal")
        #expect(tok.kind == .oauth)

        let all = try await db.claudeTokens.list()
        #expect(all.count == 1)

        let fetched = try await db.claudeTokens.get(id: tok.id)
        #expect(fetched?.id == tok.id)
    }

    @Test func getByName() async throws {
        let db = try TBDDatabase(inMemory: true)
        _ = try await db.claudeTokens.create(name: "Work", kind: .apiKey)
        let found = try await db.claudeTokens.getByName("Work")
        #expect(found?.kind == .apiKey)
        let missing = try await db.claudeTokens.getByName("Nope")
        #expect(missing == nil)
    }

    @Test func renameAndDelete() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.claudeTokens.create(name: "Old", kind: .oauth)
        try await db.claudeTokens.rename(id: tok.id, name: "New")
        let renamed = try await db.claudeTokens.get(id: tok.id)
        #expect(renamed?.name == "New")

        try await db.claudeTokens.delete(id: tok.id)
        #expect(try await db.claudeTokens.get(id: tok.id) == nil)
    }

    @Test func repoOverrideRoundTrip() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.claudeTokens.create(name: "Personal", kind: .oauth)
        let repo = try await db.repos.create(path: "/tmp/r", displayName: "r", defaultBranch: "main")
        #expect(repo.claudeTokenOverrideID == nil)

        try await db.repos.setClaudeTokenOverride(id: repo.id, tokenID: tok.id)
        let fetched = try await db.repos.get(id: repo.id)
        #expect(fetched?.claudeTokenOverrideID == tok.id)

        try await db.repos.setClaudeTokenOverride(id: repo.id, tokenID: nil)
        let cleared = try await db.repos.get(id: repo.id)
        #expect(cleared?.claudeTokenOverrideID == nil)
    }

    @Test func touchLastUsed() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.claudeTokens.create(name: "Personal", kind: .oauth)
        #expect(tok.lastUsedAt == nil)
        try await db.claudeTokens.touchLastUsed(id: tok.id)
        let updated = try await db.claudeTokens.get(id: tok.id)
        #expect(updated?.lastUsedAt != nil)
    }
}
