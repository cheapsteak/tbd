import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("model profile env_overrides")
struct ModelProfileEnvOverridesTests {
    @Test func defaultsEmpty() async throws {
        let db = try TBDDatabase(inMemory: true)
        let profile = try await db.modelProfiles.create(name: "P", kind: .oauth)
        let fetched = try await db.modelProfiles.get(id: profile.id)
        #expect(fetched?.envOverrides.isEmpty == true)
    }

    @Test func profileEnvOverridesRoundTrip() async throws {
        let db = try TBDDatabase(inMemory: true)
        let profile = try await db.modelProfiles.create(name: "P", kind: .oauth)
        try await db.modelProfiles.setEnvOverrides(id: profile.id, overrides: ["FOO": "bar"])
        let fetched = try await db.modelProfiles.get(id: profile.id)
        #expect(fetched?.envOverrides == ["FOO": "bar"])
    }

    @Test func resolverCarriesProfileEnvOverrides() async throws {
        let db = try TBDDatabase(inMemory: true)
        let resolver = ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config,
            keychain: { _ in nil }
        )
        let profile = try await db.modelProfiles.create(name: "Bedrock", kind: .bedrock,
                                                        awsRegion: "us-west-2")
        try await db.modelProfiles.setEnvOverrides(id: profile.id, overrides: ["CLAUDE_CODE_USE_BEDROCK": "1"])
        try await db.config.setDefaultProfileID(profile.id)

        let resolved = try await resolver.resolve(repoID: nil)
        #expect(resolved?.envOverrides == ["CLAUDE_CODE_USE_BEDROCK": "1"])
    }
}
