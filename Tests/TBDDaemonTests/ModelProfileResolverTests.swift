import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("ModelProfileResolver")
struct ModelProfileResolverTests {
    final class KeychainBox: @unchecked Sendable {
        var map: [String: String] = [:]
    }

    private func makeHarness() throws -> (TBDDatabase, KeychainBox, ModelProfileResolver) {
        let db = try TBDDatabase(inMemory: true)
        let box = KeychainBox()
        let resolver = ModelProfileResolver(
            profiles: db.modelProfiles,
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
            try await db.repos.setProfileOverride(id: repo.id, profileID: override)
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
        let tok = try await db.modelProfiles.create(name: "Personal", kind: .oauth)
        try await db.config.setDefaultProfileID(tok.id)
        box.map[tok.id.uuidString] = "secret-A"

        let result = try await resolver.resolve(repoID: nil)
        #expect(result?.profileID == tok.id)
        #expect(result?.name == "Personal")
        #expect(result?.kind == .oauth)
        #expect(result?.secret == "secret-A")
    }

    @Test func resolve_nilRepo_globalDefault_keychainMissing_returnsNil() async throws {
        let (db, _, resolver) = try makeHarness()
        let tok = try await db.modelProfiles.create(name: "Personal", kind: .oauth)
        try await db.config.setDefaultProfileID(tok.id)

        let result = try await resolver.resolve(repoID: nil)
        #expect(result == nil)
    }

    @Test func resolve_repoOverride_keychainPresent_overrideWins() async throws {
        let (db, box, resolver) = try makeHarness()
        let a = try await db.modelProfiles.create(name: "A", kind: .oauth)
        let b = try await db.modelProfiles.create(name: "B", kind: .apiKey)
        try await db.config.setDefaultProfileID(b.id)
        let repo = try await makeRepo(db, override: a.id)
        box.map[a.id.uuidString] = "secret-A"
        box.map[b.id.uuidString] = "secret-B"

        let result = try await resolver.resolve(repoID: repo.id)
        #expect(result?.profileID == a.id)
        #expect(result?.secret == "secret-A")
    }

    @Test func resolve_repoOverride_keychainMissing_fallsBackToGlobal() async throws {
        let (db, box, resolver) = try makeHarness()
        let a = try await db.modelProfiles.create(name: "A", kind: .oauth)
        let b = try await db.modelProfiles.create(name: "B", kind: .apiKey)
        try await db.config.setDefaultProfileID(b.id)
        let repo = try await makeRepo(db, override: a.id)
        box.map[b.id.uuidString] = "secret-B"

        let result = try await resolver.resolve(repoID: repo.id)
        #expect(result?.profileID == b.id)
        #expect(result?.secret == "secret-B")
    }

    @Test func resolve_repoNoOverride_globalSet_usesGlobal() async throws {
        let (db, box, resolver) = try makeHarness()
        let g = try await db.modelProfiles.create(name: "G", kind: .oauth)
        try await db.config.setDefaultProfileID(g.id)
        let repo = try await makeRepo(db)
        box.map[g.id.uuidString] = "secret-G"

        let result = try await resolver.resolve(repoID: repo.id)
        #expect(result?.profileID == g.id)
    }

    @Test func resolve_success_bumpsLastUsedAt() async throws {
        let (db, box, resolver) = try makeHarness()
        let tok = try await db.modelProfiles.create(name: "T", kind: .oauth)
        #expect(tok.lastUsedAt == nil)
        try await db.config.setDefaultProfileID(tok.id)
        box.map[tok.id.uuidString] = "secret"

        let before = Date()
        _ = try await resolver.resolve(repoID: nil)
        let reloaded = try await db.modelProfiles.get(id: tok.id)
        #expect(reloaded?.lastUsedAt != nil)
        if let lu = reloaded?.lastUsedAt {
            #expect(lu.timeIntervalSince(before) >= -1)
            #expect(lu.timeIntervalSinceNow >= -5)
        }
    }

    @Test func loadByID_bypassesPrecedence_andCarriesBaseURLAndModel() async throws {
        let (db, box, resolver) = try makeHarness()
        // Default profile is "Default" — would normally win the precedence chain.
        let def = try await db.modelProfiles.create(
            name: "Default",
            kind: .oauth,
            baseURL: nil,
            model: nil
        )
        try await db.config.setDefaultProfileID(def.id)
        box.map[def.id.uuidString] = "secret-default"

        // Pinned profile carries baseURL + model (proxy endpoint).
        let pinned = try await db.modelProfiles.create(
            name: "Pinned",
            kind: .apiKey,
            baseURL: "https://proxy.example.com",
            model: "claude-3-5-sonnet-20241022"
        )
        box.map[pinned.id.uuidString] = "secret-pinned"

        // loadByID returns the pinned profile, NOT the default.
        let result = try await resolver.loadByID(pinned.id)
        #expect(result?.profileID == pinned.id)
        #expect(result?.name == "Pinned")
        #expect(result?.kind == .apiKey)
        #expect(result?.baseURL == "https://proxy.example.com")
        #expect(result?.model == "claude-3-5-sonnet-20241022")
        #expect(result?.secret == "secret-pinned")
    }

    @Test func loadByID_keychainMissing_returnsNil() async throws {
        let (db, _, resolver) = try makeHarness()
        let p = try await db.modelProfiles.create(name: "P", kind: .apiKey)
        let result = try await resolver.loadByID(p.id)
        #expect(result == nil)
    }

    @Test func resolve_failure_doesNotBumpLastUsedAt() async throws {
        let (db, _, resolver) = try makeHarness()
        let tok = try await db.modelProfiles.create(name: "T", kind: .oauth)
        try await db.config.setDefaultProfileID(tok.id)
        // no keychain entry

        _ = try await resolver.resolve(repoID: nil)
        let reloaded = try await db.modelProfiles.get(id: tok.id)
        #expect(reloaded?.lastUsedAt == nil)
    }
}
