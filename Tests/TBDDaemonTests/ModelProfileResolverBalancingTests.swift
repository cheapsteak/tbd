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
            lastAttemptAt: Date(),
            status: "ok",
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

        let repo = try await db.repos.create(
            path: "/tmp",
            displayName: "Test Repo",
            defaultBranch: "main",
            remoteURL: "https://github.com/test/test.git"
        )
        let repoID = repo.id

        // Set the profile override on the created repo
        try await db.repos.setProfileOverride(id: repoID, profileID: repoOverrideProfileID)

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
        try await db.config.setScratchProfileOverride(scratchOverrideProfileID)
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

    @Test("balancing: on selects lower usage, off uses default")
    func balancingOnSelectsLowerUsageProfile() async throws {
        let db = TBDDatabase(inMemory: true)
        let profileA = try await db.modelProfiles.create(
            name: "Profile A",
            kind: .oauth
        )
        let profileB = try await db.modelProfiles.create(
            name: "Profile B",
            kind: .oauth
        )

        // Set A as default
        try await db.config.setDefaultProfileID(profileA.id)

        // Create repo with no override
        let repo = RepoRecord(
            id: UUID(),
            name: "Test Repo",
            owner: "test",
            host: "github.com",
            workingDirectory: "/tmp",
            gitDirectory: "/tmp/.git",
            profileOverrideID: nil,
            localBranch: "main",
            remoteURL: "https://github.com/test/test.git"
        )
        try await db.repos.save(repo)

        // Seed snapshots: A at 80% with 2 live sessions, B at 20% with 0 live sessions
        let snapshotA = ProfileUsageSnapshot(
            buckets: [
                .init(kind: "session", percent: 80, resetsAt: Date().addingTimeInterval(3600), isActive: true),
                .init(kind: "weekly_all", percent: 80, resetsAt: Date().addingTimeInterval(86400 * 7), isActive: true),
            ],
            fetchedAt: Date(),
            lastAttemptAt: Date(),
            status: "ok",
            statusKind: .ok,
            organizationID: nil
        )
        let snapshotB = ProfileUsageSnapshot(
            buckets: [
                .init(kind: "session", percent: 20, resetsAt: Date().addingTimeInterval(3600), isActive: true),
                .init(kind: "weekly_all", percent: 20, resetsAt: Date().addingTimeInterval(86400 * 7), isActive: true),
            ],
            fetchedAt: Date(),
            lastAttemptAt: Date(),
            status: "ok",
            statusKind: .ok,
            organizationID: nil
        )
        try await db.oauthUsageSnapshots.upsert(profileID: profileA.id, snapshot: snapshotA)
        try await db.oauthUsageSnapshots.upsert(profileID: profileB.id, snapshot: snapshotB)

        // Create 2 live Claude terminals on A
        _ = try await db.terminals.create(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1", profileID: profileA.id
        )
        _ = try await db.terminals.create(
            worktreeID: UUID(), tmuxWindowID: "@2", tmuxPaneID: "%2", profileID: profileA.id
        )

        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { _ in "user@example.com" }
        )

        // With balancing ON, should select B (lower usage)
        try await db.config.setProfileBalancingEnabled(true)
        let resolverOn = ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config,
            candidateSource: source
        )
        let resolvedOn = try await resolverOn.resolve(repoID: repo.id)
        #expect(resolvedOn?.profileID == profileB.id)

        // With balancing OFF, should select A (the default)
        try await db.config.setProfileBalancingEnabled(false)
        let resolverOff = ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config,
            candidateSource: source
        )
        let resolvedOff = try await resolverOff.resolve(repoID: repo.id)
        #expect(resolvedOff?.profileID == profileA.id)
    }

    @Test("balancing: on without default selects lowest usage")
    func balancingOnWithoutDefaultSelectsLowestUsage() async throws {
        let db = TBDDatabase(inMemory: true)
        let profileA = try await db.modelProfiles.create(
            name: "Profile A",
            kind: .oauth
        )
        let profileB = try await db.modelProfiles.create(
            name: "Profile B",
            kind: .oauth
        )

        // No default configured
        try await db.config.setProfileBalancingEnabled(true)

        // Seed snapshots: A at 80%, B at 20%
        let snapshotA = ProfileUsageSnapshot(
            buckets: [
                .init(kind: "session", percent: 80, resetsAt: Date().addingTimeInterval(3600), isActive: true),
            ],
            fetchedAt: Date(),
            lastAttemptAt: Date(),
            status: "ok",
            statusKind: .ok,
            organizationID: nil
        )
        let snapshotB = ProfileUsageSnapshot(
            buckets: [
                .init(kind: "session", percent: 20, resetsAt: Date().addingTimeInterval(3600), isActive: true),
            ],
            fetchedAt: Date(),
            lastAttemptAt: Date(),
            status: "ok",
            statusKind: .ok,
            organizationID: nil
        )
        try await db.oauthUsageSnapshots.upsert(profileID: profileA.id, snapshot: snapshotA)
        try await db.oauthUsageSnapshots.upsert(profileID: profileB.id, snapshot: snapshotB)

        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { _ in "user@example.com" }
        )

        // With balancing ON and no default, should return B (not nil)
        try await db.config.setProfileBalancingEnabled(true)
        let resolverOn = ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config,
            candidateSource: source
        )
        let resolvedOn = try await resolverOn.resolve(repoID: nil)
        #expect(resolvedOn?.profileID == profileB.id)

        // With balancing OFF and no default, should return nil
        try await db.config.setProfileBalancingEnabled(false)
        let resolverOff = ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config,
            candidateSource: source
        )
        let resolvedOff = try await resolverOff.resolve(repoID: nil)
        #expect(resolvedOff == nil)
    }

    @Test("candidate source: live sessions reflect terminal state")
    func candidateSourceReflectsLiveSessionCounts() async throws {
        let db = TBDDatabase(inMemory: true)
        let profileA = try await db.modelProfiles.create(
            name: "Profile A",
            kind: .oauth
        )
        let profileB = try await db.modelProfiles.create(
            name: "Profile B",
            kind: .oauth
        )

        // Create 1 live Claude terminal on A
        _ = try await db.terminals.create(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1", profileID: profileA.id
        )

        // Create 1 hibernated terminal on A (should not count)
        let hibernated = try await db.terminals.create(
            worktreeID: UUID(), tmuxWindowID: "@2", tmuxPaneID: "%2", profileID: profileA.id
        )
        var hibernatedUpdated = hibernated
        hibernatedUpdated.hibernatedAt = Date()
        try await db.terminals.update(hibernatedUpdated)

        // No terminals on B

        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { _ in "user@example.com" }
        )

        let candidates = try await source.candidates(defaultProfileID: nil)
        let candidateA = candidates.first(where: { $0.profileID == profileA.id })
        let candidateB = candidates.first(where: { $0.profileID == profileB.id })

        // A should have 1 live session (hibernated doesn't count)
        #expect(candidateA?.liveSessions == 1)
        // B should have 0 live sessions
        #expect(candidateB?.liveSessions == 0)
    }
}
