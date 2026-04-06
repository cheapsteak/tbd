import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("ClaudeTokenResolver")
struct ClaudeTokenResolverTests {
    final class KeychainBox: @unchecked Sendable {
        var map: [String: String] = [:]
    }

    private func makeHarness() throws -> (TBDDatabase, KeychainBox, ClaudeTokenResolver) {
        let db = try TBDDatabase(inMemory: true)
        let box = KeychainBox()
        let resolver = ClaudeTokenResolver(
            tokens: db.claudeTokens,
            repos: db.repos,
            config: db.config,
            keychain: { id in box.map[id] }
        )
        return (db, box, resolver)
    }

    private func makeRepo(_ db: TBDDatabase, override: UUID? = nil) async throws -> Repo {
        let repo = try await db.repos.create(
            path: "/tmp/repo-\(UUID().uuidString)",
            displayName: "repo",
            defaultBranch: "main"
        )
        if let override {
            try await db.repos.setClaudeTokenOverride(id: repo.id, tokenID: override)
        }
        return repo
    }

    @Test func resolve_nilRepo_noDefault_returnsNil() async throws {
        let (_, _, resolver) = try makeHarness()
        let result = try await resolver.resolve(repoID: nil)
        #expect(result == nil)
    }

    @Test func resolve_nilRepo_globalDefault_keychainPresent_returnsResolved() async throws {
        let (db, box, resolver) = try makeHarness()
        let tok = try await db.claudeTokens.create(name: "Personal", kind: .oauth)
        try await db.config.setDefaultClaudeTokenID(tok.id)
        box.map[tok.id.uuidString] = "secret-A"

        let result = try await resolver.resolve(repoID: nil)
        #expect(result?.tokenID == tok.id)
        #expect(result?.name == "Personal")
        #expect(result?.kind == .oauth)
        #expect(result?.secret == "secret-A")
    }

    @Test func resolve_nilRepo_globalDefault_keychainMissing_returnsNil() async throws {
        let (db, _, resolver) = try makeHarness()
        let tok = try await db.claudeTokens.create(name: "Personal", kind: .oauth)
        try await db.config.setDefaultClaudeTokenID(tok.id)

        let result = try await resolver.resolve(repoID: nil)
        #expect(result == nil)
    }

    @Test func resolve_repoOverride_keychainPresent_overrideWins() async throws {
        let (db, box, resolver) = try makeHarness()
        let a = try await db.claudeTokens.create(name: "A", kind: .oauth)
        let b = try await db.claudeTokens.create(name: "B", kind: .apiKey)
        try await db.config.setDefaultClaudeTokenID(b.id)
        let repo = try await makeRepo(db, override: a.id)
        box.map[a.id.uuidString] = "secret-A"
        box.map[b.id.uuidString] = "secret-B"

        let result = try await resolver.resolve(repoID: repo.id)
        #expect(result?.tokenID == a.id)
        #expect(result?.secret == "secret-A")
    }

    @Test func resolve_repoOverride_keychainMissing_fallsBackToGlobal() async throws {
        let (db, box, resolver) = try makeHarness()
        let a = try await db.claudeTokens.create(name: "A", kind: .oauth)
        let b = try await db.claudeTokens.create(name: "B", kind: .apiKey)
        try await db.config.setDefaultClaudeTokenID(b.id)
        let repo = try await makeRepo(db, override: a.id)
        box.map[b.id.uuidString] = "secret-B"

        let result = try await resolver.resolve(repoID: repo.id)
        #expect(result?.tokenID == b.id)
        #expect(result?.secret == "secret-B")
    }

    @Test func resolve_repoNoOverride_globalSet_usesGlobal() async throws {
        let (db, box, resolver) = try makeHarness()
        let g = try await db.claudeTokens.create(name: "G", kind: .oauth)
        try await db.config.setDefaultClaudeTokenID(g.id)
        let repo = try await makeRepo(db)
        box.map[g.id.uuidString] = "secret-G"

        let result = try await resolver.resolve(repoID: repo.id)
        #expect(result?.tokenID == g.id)
    }

    @Test func resolve_success_bumpsLastUsedAt() async throws {
        let (db, box, resolver) = try makeHarness()
        let tok = try await db.claudeTokens.create(name: "T", kind: .oauth)
        #expect(tok.lastUsedAt == nil)
        try await db.config.setDefaultClaudeTokenID(tok.id)
        box.map[tok.id.uuidString] = "secret"

        let before = Date()
        _ = try await resolver.resolve(repoID: nil)
        let reloaded = try await db.claudeTokens.get(id: tok.id)
        #expect(reloaded?.lastUsedAt != nil)
        if let lu = reloaded?.lastUsedAt {
            #expect(lu.timeIntervalSince(before) >= -1)
            #expect(lu.timeIntervalSinceNow >= -5)
        }
    }

    @Test func resolve_failure_doesNotBumpLastUsedAt() async throws {
        let (db, _, resolver) = try makeHarness()
        let tok = try await db.claudeTokens.create(name: "T", kind: .oauth)
        try await db.config.setDefaultClaudeTokenID(tok.id)
        // no keychain entry

        _ = try await resolver.resolve(repoID: nil)
        let reloaded = try await db.claudeTokens.get(id: tok.id)
        #expect(reloaded?.lastUsedAt == nil)
    }
}
