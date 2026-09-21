import Foundation
import Testing
import TBDShared

@testable import TBDDaemonLib

struct ModelProfileResolverBalancingTests {
    // MARK: - ProfilePoolCandidateSource Unit Tests

    @Test
    func candidateSourceHashCredentialForOAuth() async throws {
        let db = TBDDatabase(inMemory: true)
        let profile = ModelProfileRecord(
            id: UUID(),
            name: "Test OAuth",
            kind: .oauth,
            sortOrder: 0,
            poolOptOut: nil,
            profileOverrideID: nil,
            baseURL: nil,
            model: nil,
            awsRegion: nil,
            awsProfile: nil,
            fallbackModels: nil,
            envOverrides: [:]
        )
        try await db.modelProfiles.save(profile)

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
        let profile = ModelProfileRecord(
            id: UUID(),
            name: "Test OAuth No Cred",
            kind: .oauth,
            sortOrder: 0,
            poolOptOut: nil,
            profileOverrideID: nil,
            baseURL: nil,
            model: nil,
            awsRegion: nil,
            awsProfile: nil,
            fallbackModels: nil,
            envOverrides: [:]
        )
        try await db.modelProfiles.save(profile)

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
        let profileID = UUID()
        let profile = ModelProfileRecord(
            id: profileID,
            name: "Test Account Key",
            kind: .oauth,
            sortOrder: 0,
            poolOptOut: nil,
            profileOverrideID: nil,
            baseURL: nil,
            model: nil,
            awsRegion: nil,
            awsProfile: nil,
            fallbackModels: nil,
            envOverrides: [:]
        )
        try await db.modelProfiles.save(profile)

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
        let profileID = UUID()
        let profile = ModelProfileRecord(
            id: profileID,
            name: "Test Account Key",
            kind: .oauth,
            sortOrder: 0,
            poolOptOut: nil,
            profileOverrideID: nil,
            baseURL: nil,
            model: nil,
            awsRegion: nil,
            awsProfile: nil,
            fallbackModels: nil,
            envOverrides: [:]
        )
        try await db.modelProfiles.save(profile)

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
        let profileID = UUID()
        let profile = ModelProfileRecord(
            id: profileID,
            name: "Test Account Key",
            kind: .oauth,
            sortOrder: 0,
            poolOptOut: nil,
            profileOverrideID: nil,
            baseURL: nil,
            model: nil,
            awsRegion: nil,
            awsProfile: nil,
            fallbackModels: nil,
            envOverrides: [:]
        )
        try await db.modelProfiles.save(profile)

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
        let profileID = UUID()
        let profile = ModelProfileRecord(
            id: profileID,
            name: "Default Profile",
            kind: .oauth,
            sortOrder: 0,
            poolOptOut: nil,
            profileOverrideID: nil,
            baseURL: nil,
            model: nil,
            awsRegion: nil,
            awsProfile: nil,
            fallbackModels: nil,
            envOverrides: [:]
        )
        try await db.modelProfiles.save(profile)

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
        let defaultProfileID = UUID()
        let defaultProfile = ModelProfileRecord(
            id: defaultProfileID,
            name: "Default",
            kind: .oauth,
            sortOrder: 0,
            poolOptOut: nil,
            profileOverrideID: nil,
            baseURL: nil,
            model: nil,
            awsRegion: nil,
            awsProfile: nil,
            fallbackModels: nil,
            envOverrides: [:]
        )
        try await db.modelProfiles.save(defaultProfile)

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
        let defaultProfileID = UUID()
        let overrideProfileID = UUID()

        let defaultProfile = ModelProfileRecord(
            id: defaultProfileID,
            name: "Default",
            kind: .oauth,
            sortOrder: 0,
            poolOptOut: nil,
            profileOverrideID: nil,
            baseURL: nil,
            model: nil,
            awsRegion: nil,
            awsProfile: nil,
            fallbackModels: nil,
            envOverrides: [:]
        )
        let overrideProfile = ModelProfileRecord(
            id: overrideProfileID,
            name: "Override",
            kind: .oauth,
            sortOrder: 1,
            poolOptOut: nil,
            profileOverrideID: nil,
            baseURL: nil,
            model: nil,
            awsRegion: nil,
            awsProfile: nil,
            fallbackModels: nil,
            envOverrides: [:]
        )
        try await db.modelProfiles.save(defaultProfile)
        try await db.modelProfiles.save(overrideProfile)

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
        let defaultProfileID = UUID()
        let defaultProfile = ModelProfileRecord(
            id: defaultProfileID,
            name: "Default",
            kind: .oauth,
            sortOrder: 0,
            poolOptOut: nil,
            profileOverrideID: nil,
            baseURL: nil,
            model: nil,
            awsRegion: nil,
            awsProfile: nil,
            fallbackModels: nil,
            envOverrides: [:]
        )
        try await db.modelProfiles.save(defaultProfile)

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
        let repoID = UUID()
        let defaultProfileID = UUID()
        let repoOverrideProfileID = UUID()

        let repo = RepoRecord(
            id: repoID,
            name: "Test Repo",
            owner: "test",
            host: "github.com",
            workingDirectory: "/tmp",
            gitDirectory: "/tmp/.git",
            profileOverrideID: repoOverrideProfileID,
            localBranch: "main",
            remoteURL: "https://github.com/test/test.git"
        )
        let defaultProfile = ModelProfileRecord(
            id: defaultProfileID,
            name: "Default",
            kind: .oauth,
            sortOrder: 0,
            poolOptOut: nil,
            profileOverrideID: nil,
            baseURL: nil,
            model: nil,
            awsRegion: nil,
            awsProfile: nil,
            fallbackModels: nil,
            envOverrides: [:]
        )
        let repoOverrideProfile = ModelProfileRecord(
            id: repoOverrideProfileID,
            name: "Repo Override",
            kind: .oauth,
            sortOrder: 1,
            poolOptOut: nil,
            profileOverrideID: nil,
            baseURL: nil,
            model: nil,
            awsRegion: nil,
            awsProfile: nil,
            fallbackModels: nil,
            envOverrides: [:]
        )

        try await db.repos.save(repo)
        try await db.modelProfiles.save(defaultProfile)
        try await db.modelProfiles.save(repoOverrideProfile)

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
        let defaultProfileID = UUID()
        let scratchOverrideProfileID = UUID()

        let defaultProfile = ModelProfileRecord(
            id: defaultProfileID,
            name: "Default",
            kind: .oauth,
            sortOrder: 0,
            poolOptOut: nil,
            profileOverrideID: nil,
            baseURL: nil,
            model: nil,
            awsRegion: nil,
            awsProfile: nil,
            fallbackModels: nil,
            envOverrides: [:]
        )
        let scratchOverrideProfile = ModelProfileRecord(
            id: scratchOverrideProfileID,
            name: "Scratch Override",
            kind: .oauth,
            sortOrder: 1,
            poolOptOut: nil,
            profileOverrideID: nil,
            baseURL: nil,
            model: nil,
            awsRegion: nil,
            awsProfile: nil,
            fallbackModels: nil,
            envOverrides: [:]
        )

        try await db.modelProfiles.save(defaultProfile)
        try await db.modelProfiles.save(scratchOverrideProfile)

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
        let defaultProfileID = UUID()
        let defaultProfile = ModelProfileRecord(
            id: defaultProfileID,
            name: "Default",
            kind: .oauth,
            sortOrder: 0,
            poolOptOut: nil,
            profileOverrideID: nil,
            baseURL: nil,
            model: nil,
            awsRegion: nil,
            awsProfile: nil,
            fallbackModels: nil,
            envOverrides: [:]
        )
        try await db.modelProfiles.save(defaultProfile)

        try await db.config.setDefaultProfileID(defaultProfileID)
        try await db.config.setProfileBalancingEnabled(true)

        // Create a throwing source
        struct ThrowingSource: Sendable {
            func candidates(defaultProfileID: UUID?) async throws -> [ProfilePoolCandidate] {
                throw NSError(domain: "test", code: 1)
            }
        }

        // Use a source that will throw by creating a real one with a failing implementation
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
    func nothingEligibleFallsBackToDefault() async throws {
        let db = TBDDatabase(inMemory: true)
        let defaultProfileID = UUID()
        let defaultProfile = ModelProfileRecord(
            id: defaultProfileID,
            name: "Default",
            kind: .apiKey,
            sortOrder: 0,
            poolOptOut: nil,
            profileOverrideID: nil,
            baseURL: nil,
            model: nil,
            awsRegion: nil,
            awsProfile: nil,
            fallbackModels: nil,
            envOverrides: [:]
        )
        try await db.modelProfiles.save(defaultProfile)

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
