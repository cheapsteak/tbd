import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("ModelProfileMigration")
struct ModelProfileMigrationTests {

    @Test("v15 renames claude_tokens to model_profiles, adds columns, and ports config + repo + terminal references")
    func migrationRenamesAndAddsColumns() async throws {
        // Bring up an in-memory DB (which runs all migrations) and assert the
        // resulting schema.
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { conn in
            // model_profiles table exists with the new columns.
            let cols = try Row.fetchAll(conn, sql: "PRAGMA table_info(model_profiles)")
                .map { $0["name"] as String }
            #expect(cols.contains("id"))
            #expect(cols.contains("name"))
            #expect(cols.contains("keychain_ref"))
            #expect(cols.contains("kind"))
            #expect(cols.contains("created_at"))
            #expect(cols.contains("last_used_at"))
            #expect(cols.contains("base_url"))
            #expect(cols.contains("model"))

            // claude_tokens no longer exists.
            let oldExists = try Bool.fetchOne(
                conn,
                sql: "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='claude_tokens'"
            ) ?? true
            #expect(oldExists == false)

            // model_profile_usage table exists (renamed from claude_token_usage).
            let usageExists = try Bool.fetchOne(
                conn,
                sql: "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='model_profile_usage'"
            ) ?? false
            #expect(usageExists)

            // model_profile_usage uses profile_id (renamed from token_id).
            let usageCols = try Row.fetchAll(conn, sql: "PRAGMA table_info(model_profile_usage)")
                .map { $0["name"] as String }
            #expect(usageCols.contains("profile_id"))
            #expect(!usageCols.contains("token_id"))

            // config has default_profile_id, NOT default_claude_token_id.
            let configCols = try Row.fetchAll(conn, sql: "PRAGMA table_info(config)")
                .map { $0["name"] as String }
            #expect(configCols.contains("default_profile_id"))
            #expect(!configCols.contains("default_claude_token_id"))

            // repo has profile_override_id.
            let repoCols = try Row.fetchAll(conn, sql: "PRAGMA table_info(repo)")
                .map { $0["name"] as String }
            #expect(repoCols.contains("profile_override_id"))
            #expect(!repoCols.contains("claude_token_override_id"))

            // terminal has profile_id (replaces claude_token_id).
            let termCols = try Row.fetchAll(conn, sql: "PRAGMA table_info(terminal)")
                .map { $0["name"] as String }
            #expect(termCols.contains("profile_id"))
            #expect(!termCols.contains("claude_token_id"))
        }
    }

    @Test("ModelProfile round-trips through the store with baseURL/model nil and non-nil")
    func dataPreservationRoundTrip() async throws {
        let db = try TBDDatabase(inMemory: true)

        // Case 1: baseURL = nil, model = nil — Anthropic-direct profile.
        let direct = try await db.modelProfiles.create(
            name: "Direct",
            kind: .oauth,
            baseURL: nil,
            model: nil
        )
        let directReloaded = try await db.modelProfiles.get(id: direct.id)
        #expect(directReloaded?.id == direct.id)
        #expect(directReloaded?.name == "Direct")
        #expect(directReloaded?.kind == .oauth)
        #expect(directReloaded?.baseURL == nil)
        #expect(directReloaded?.model == nil)

        // Case 2: baseURL + model set — proxy/compatible-endpoint profile.
        let proxy = try await db.modelProfiles.create(
            name: "Proxy",
            kind: .apiKey,
            baseURL: "https://proxy.example.com",
            model: "claude-3-5-sonnet-20241022"
        )
        let proxyReloaded = try await db.modelProfiles.get(id: proxy.id)
        #expect(proxyReloaded?.id == proxy.id)
        #expect(proxyReloaded?.name == "Proxy")
        #expect(proxyReloaded?.kind == .apiKey)
        #expect(proxyReloaded?.baseURL == "https://proxy.example.com")
        #expect(proxyReloaded?.model == "claude-3-5-sonnet-20241022")

        // updateEndpoint round-trip: clear and re-set the endpoint fields.
        try await db.modelProfiles.updateEndpoint(id: proxy.id, baseURL: nil, model: nil)
        let cleared = try await db.modelProfiles.get(id: proxy.id)
        #expect(cleared?.baseURL == nil)
        #expect(cleared?.model == nil)

        try await db.modelProfiles.updateEndpoint(
            id: proxy.id,
            baseURL: "https://other.example.com",
            model: "claude-3-opus"
        )
        let updated = try await db.modelProfiles.get(id: proxy.id)
        #expect(updated?.baseURL == "https://other.example.com")
        #expect(updated?.model == "claude-3-opus")
    }
}
