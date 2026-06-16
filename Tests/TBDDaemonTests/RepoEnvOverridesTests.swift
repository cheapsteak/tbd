import Testing
@testable import TBDDaemonLib

@Suite("repo env_overrides")
struct RepoEnvOverridesTests {
    @Test func defaultsEmpty() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/env", displayName: "env", defaultBranch: "main")
        let fetched = try await db.repos.get(id: repo.id)
        #expect(fetched?.envOverrides.isEmpty == true)
    }

    @Test func repoEnvOverridesRoundTrip() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/env2", displayName: "env2", defaultBranch: "main")
        try await db.repos.setEnvOverrides(id: repo.id, overrides: ["CLAUDE_CODE_USE_BEDROCK": "1", "AWS_REGION": "us-west-2"])
        let fetched = try await db.repos.get(id: repo.id)
        #expect(fetched?.envOverrides == ["CLAUDE_CODE_USE_BEDROCK": "1", "AWS_REGION": "us-west-2"])
    }
}
