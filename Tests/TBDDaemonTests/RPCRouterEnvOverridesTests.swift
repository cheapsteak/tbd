import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

// RPC handlers for the three free-form env-override scopes
// (config.setEnvOverrides / repo.setEnvOverrides / modelProfile.setEnvOverrides).
// Each routes through `router.handle` and asserts the value persisted to the DB,
// mirroring the round-trip style of RPCRouterRepoTests.
extension RPCRouterTests {

    @Test("config.setEnvOverrides persists the global overrides")
    func configSetEnvOverrides() async throws {
        let request = try RPCRequest(
            method: RPCMethod.configSetEnvOverrides,
            params: SetGlobalEnvOverridesParams(overrides: ["CLAUDE_CODE_USE_BEDROCK": "1"])
        )
        let response = await router.handle(request)
        #expect(response.success)

        let config = try await db.config.get()
        #expect(config.envOverrides == ["CLAUDE_CODE_USE_BEDROCK": "1"])
    }

    @Test("config.setEnvOverrides with empty dict clears the column")
    func configSetEnvOverridesEmptyClears() async throws {
        try await db.config.setEnvOverrides(["A": "1"])

        let request = try RPCRequest(
            method: RPCMethod.configSetEnvOverrides,
            params: SetGlobalEnvOverridesParams(overrides: [:])
        )
        let response = await router.handle(request)
        #expect(response.success)

        let config = try await db.config.get()
        #expect(config.envOverrides == [:])
    }

    @Test("repo.setEnvOverrides persists per-repo overrides")
    func repoSetEnvOverrides() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )

        let request = try RPCRequest(
            method: RPCMethod.repoSetEnvOverrides,
            params: SetRepoEnvOverridesParams(repoID: repo.id, overrides: ["FOO": "bar"])
        )
        let response = await router.handle(request)
        #expect(response.success)

        let stored = try await db.repos.get(id: repo.id)
        #expect(stored?.envOverrides == ["FOO": "bar"])
    }

    @Test("modelProfile.setEnvOverrides persists per-profile overrides")
    func modelProfileSetEnvOverrides() async throws {
        let profile = try await db.modelProfiles.create(name: "P", kind: .oauth)

        let request = try RPCRequest(
            method: RPCMethod.modelProfileSetEnvOverrides,
            params: SetProfileEnvOverridesParams(profileID: profile.id, overrides: ["X": "y"])
        )
        let response = await router.handle(request)
        #expect(response.success)

        let stored = try await db.modelProfiles.get(id: profile.id)
        #expect(stored?.envOverrides == ["X": "y"])
    }
}
