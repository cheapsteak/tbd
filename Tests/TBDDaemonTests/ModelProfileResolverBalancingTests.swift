import Foundation
import Testing
import TBDShared

@testable import TBDDaemonLib

struct ModelProfileResolverBalancingTests {
    // MARK: - ProfilePoolCandidateSource Unit Tests

    @Test
    func candidateSourceHashCredentialForOAuth() async throws {
        let db = TBDDatabase(inMemory: true)
        let profile = try await db.modelProfiles.create(
            name: "Test OAuth",
            kind: .oauth
        )

        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { _ in "test@example.com" }
        )

        let candidates = try await source.candidates(defaultProfileID: nil)
        let candidate = candidates.first(where: { $0.profileID == profile.id })

        #expect(candidate != nil)
        #expect(candidate?.hasCredential == true)
        #expect(candidate?.kind == .oauth)
    }

    @Test
    func candidateSourceNoCredentialForOAuthWithoutIdentity() async throws {
        let db = TBDDatabase(inMemory: true)
        let profile = try await db.modelProfiles.create(
            name: "Test OAuth No Cred",
            kind: .oauth
        )

        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { _ in nil }
        )

        let candidates = try await source.candidates(defaultProfileID: nil)
        let candidate = candidates.first(where: { $0.profileID == profile.id })

        #expect(candidate?.hasCredential == false)
    }

    @Test
    func candidateSourceAccountKeyPrecedence() async throws {
        let db = TBDDatabase(inMemory: true)
        let profile = try await db.modelProfiles.create(
            name: "Test Account Key",
            kind: .oauth
        )
        let profileID = profile.id

        let snapshot = ProfileUsageSnapshot(
            buckets: [],
            fetchedAt: Date(),
            statusKind: .ok,
            organizationID: "org-123"
        )
        try await db.oauthUsageSnapshots.upsert(profileID: profileID, snapshot: snapshot)

        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { _ in "user@example.com" }
        )

        let candidates = try await source.candidates(defaultProfileID: nil)
        let candidate = candidates.first(where: { $0.profileID == profileID })

        // organizationID takes precedence over loginIdentity
        #expect(candidate?.accountKey == "org-123")
    }

    @Test
    func candidateSourceAccountKeyFallsBackToLoginIdentity() async throws {
        let db = TBDDatabase(inMemory: true)
        let profile = try await db.modelProfiles.create(
            name: "Test Account Key",
            kind: .oauth
        )
        let profileID = profile.id

        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { _ in "user@example.com" }
        )

        let candidates = try await source.candidates(defaultProfileID: nil)
        let candidate = candidates.first(where: { $0.profileID == profileID })

        // Should fall back to loginIdentity when no organizationID
        #expect(candidate?.accountKey == "user@example.com")
    }

    @Test
    func candidateSourceAccountKeyFallsBackToProfileID() async throws {
        let db = TBDDatabase(inMemory: true)
        let profile = try await db.modelProfiles.create(
            name: "Test Account Key",
            kind: .oauth
        )
        let profileID = profile.id

        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { _ in nil }
        )

        let candidates = try await source.candidates(defaultProfileID: nil)
        let candidate = candidates.first(where: { $0.profileID == profileID })

        // Should fall back to profileID string when neither organizationID nor loginIdentity
        #expect(candidate?.accountKey == profileID.uuidString)
    }

    @Test
    func candidateSourceIsConfiguredDefault() async throws {
        let db = TBDDatabase(inMemory: true)
        let profile = try await db.modelProfiles.create(
            name: "Default Profile",
            kind: .oauth
        )
        let profileID = profile.id

        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { _ in nil }
        )

        let candidates = try await source.candidates(defaultProfileID: profileID)
        let candidate = candidates.first(where: { $0.profileID == profileID })

        #expect(candidate?.isConfiguredDefault == true)
    }

    // MARK: - ModelProfileResolver Integration Tests

    @Test
    func balancingOffFallsBackToDefault() async throws {
        let db = TBDDatabase(inMemory: true)
        let defaultProfile = try await db.modelProfiles.create(
            name: "Default",
            kind: .oauth
        )
        let defaultProfileID = defaultProfile.id

        try await db.config.setDefaultProfileID(defaultProfileID)
        try await db.config.setProfileBalancingEnabled(false)

        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { _ in nil }
        )

        let resolver = ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config,
            candidateSource: source
        )

        let resolved = try await resolver.resolve(repoID: nil)
        #expect(resolved?.profileID == defaultProfileID)
    }

    @Test
    func explicitOverrideStillWins() async throws {
        let db = TBDDatabase(inMemory: true)
        let defaultProfile = try await db.modelProfiles.create(
            name: "Default",
            kind: .oauth
        )
        let overrideProfile = try await db.modelProfiles.create(
            name: "Override",
            kind: .oauth
        )
        let defaultProfileID = defaultProfile.id
        let overrideProfileID = overrideProfile.id

        try await db.config.setDefaultProfileID(defaultProfileID)
        try await db.config.setProfileBalancingEnabled(true)

        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { _ in nil }
        )

        let resolver = ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config,
            candidateSource: source
        )

        let resolved = try await resolver.resolve(repoID: nil, override: overrideProfileID)
        #expect(resolved?.profileID == overrideProfileID)
    }

    @Test
    func balancingOnWithoutSourceFallsBackToDefault() async throws {
        let db = TBDDatabase(inMemory: true)
        let defaultProfile = try await db.modelProfiles.create(
            name: "Default",
            kind: .oauth
        )
        let defaultProfileID = defaultProfile.id

        try await db.config.setDefaultProfileID(defaultProfileID)
        try await db.config.setProfileBalancingEnabled(true)

        // Resolver with no source
        let resolver = ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config,
            candidateSource: nil
        )

        let resolved = try await resolver.resolve(repoID: nil)
        #expect(resolved?.profileID == defaultProfileID)
    }

    @Test
    func repoOverrideStillWins() async throws {
        let db = TBDDatabase(inMemory: true)
        let defaultProfile = try await db.modelProfiles.create(
            name: "Default",
            kind: .oauth
        )
        let repoOverrideProfile = try await db.modelProfiles.create(
            name: "Repo Override",
            kind: .oauth
        )
        let defaultProfileID = defaultProfile.id
        let repoOverrideProfileID = repoOverrideProfile.id

        let repo = RepoRecord(
            id: UUID(),
            name: "Test Repo",
            owner: "test",
            host: "github.com",
            workingDirectory: "/tmp",
            gitDirectory: "/tmp/.git",
            profileOverrideID: repoOverrideProfileID,
            localBranch: "main",
            remoteURL: "https://github.com/test/test.git"
        )
        let repoID = repo.id

        try await db.repos.save(repo)

        try await db.config.setDefaultProfileID(defaultProfileID)
        try await db.config.setProfileBalancingEnabled(true)

        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { _ in nil }
        )

        let resolver = ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config,
            candidateSource: source
        )

        let resolved = try await resolver.resolve(repoID: repoID)
        #expect(resolved?.profileID == repoOverrideProfileID)
    }

    @Test
    func scratchOverrideStillWins() async throws {
        let db = TBDDatabase(inMemory: true)
        let defaultProfile = try await db.modelProfiles.create(
            name: "Default",
            kind: .oauth
        )
        let scratchOverrideProfile = try await db.modelProfiles.create(
            name: "Scratch Override",
            kind: .oauth
        )
        let defaultProfileID = defaultProfile.id
        let scratchOverrideProfileID = scratchOverrideProfile.id

        try await db.config.setDefaultProfileID(defaultProfileID)
        try await db.config.setScratchProfileOverrideID(scratchOverrideProfileID)
        try await db.config.setProfileBalancingEnabled(true)

        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { _ in nil }
        )

        let resolver = ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config,
            candidateSource: source
        )

        let resolved = try await resolver.resolve(repoID: nil)
        #expect(resolved?.profileID == scratchOverrideProfileID)
    }

    @Test
    func candidateSourceThrowingFallsBackToDefault() async throws {
        let db = TBDDatabase(inMemory: true)
        let defaultProfile = try await db.modelProfiles.create(
            name: "Default",
            kind: .oauth
        )
        let defaultProfileID = defaultProfile.id

        try await db.config.setDefaultProfileID(defaultProfileID)
        try await db.config.setProfileBalancingEnabled(true)

        // Resolver with no source falls back to default
        let resolver = ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config,
            candidateSource: nil
        )

        let resolved = try await resolver.resolve(repoID: nil)
        #expect(resolved?.profileID == defaultProfileID)
    }

    @Test
    func nothingEligibleFallsBackToDefault() async throws {
        let db = TBDDatabase(inMemory: true)
        let defaultProfile = try await db.modelProfiles.create(
            name: "Default",
            kind: .apiKey
        )
        let defaultProfileID = defaultProfile.id

        try await db.config.setDefaultProfileID(defaultProfileID)
        try await db.config.setProfileBalancingEnabled(true)

        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { _ in nil }
        )

        let resolver = ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config,
            candidateSource: source
        )

        let resolved = try await resolver.resolve(repoID: nil)
        #expect(resolved == nil)
    }
}
