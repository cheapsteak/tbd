import Testing
@testable import TBDDaemonLib

@Suite("repo claude_settings_overlay")
struct RepoClaudeSettingsOverlayTests {
    @Test func defaultsNil() async throws {
        // Rows created without the field (and pre-v53 rows, which the
        // migration leaves NULL) decode as nil.
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/cso", displayName: "cso", defaultBranch: "main")
        let fetched = try await db.repos.get(id: repo.id)
        #expect(fetched?.claudeSettingsOverlay == nil)
    }

    @Test func overlayRoundTrip() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/cso2", displayName: "cso2", defaultBranch: "main")
        let fragment = #"{"skillOverrides":{"heavy-skill":"off"}}"#
        try await db.repos.setClaudeSettingsOverlay(id: repo.id, overlay: fragment)
        let fetched = try await db.repos.get(id: repo.id)
        #expect(fetched?.claudeSettingsOverlay == fragment)
    }

    @Test func nilClearsToNull() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/cso3", displayName: "cso3", defaultBranch: "main")
        try await db.repos.setClaudeSettingsOverlay(id: repo.id, overlay: "{}")
        try await db.repos.setClaudeSettingsOverlay(id: repo.id, overlay: nil)
        let fetched = try await db.repos.get(id: repo.id)
        #expect(fetched?.claudeSettingsOverlay == nil)
    }
}
