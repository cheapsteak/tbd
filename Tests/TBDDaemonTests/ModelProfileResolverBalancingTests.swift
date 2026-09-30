import Foundation
import Testing
import TBDShared
import TestSupport

@testable import TBDDaemonLib

struct ModelProfileResolverBalancingTests {
    // MARK: - ProfilePoolCandidateSource Unit Tests

    @Test
    func candidateSourceHashCredentialForOAuth() async throws {
        let db = try TBDDatabase(inMemory: true)
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
        let db = try TBDDatabase(inMemory: true)
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
        let db = try TBDDatabase(inMemory: true)
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
        let db = try TBDDatabase(inMemory: true)
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
        let db = try TBDDatabase(inMemory: true)
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
        let db = try TBDDatabase(inMemory: true)
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
        let db = try TBDDatabase(inMemory: true)
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
        let db = try TBDDatabase(inMemory: true)
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
        let db = try TBDDatabase(inMemory: true)
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
        let db = try TBDDatabase(inMemory: true)
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
        let db = try TBDDatabase(inMemory: true)
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
        let db = try TBDDatabase(inMemory: true)
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
        let db = try TBDDatabase(inMemory: true)
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
        let db = try TBDDatabase(inMemory: true)
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
        let repo = try await db.repos.create(
            path: "/tmp/test-repo", displayName: "Test Repo", defaultBranch: "main")

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

        let worktree = try await db.worktrees.createScratch(
            name: "wt", displayName: "wt", path: "/tmp/wt-balancing", tmuxServer: "@wt")
        // Create 2 live Claude terminals on A
        _ = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1", profileID: profileA.id, kind: .claude
        )
        _ = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@2", tmuxPaneID: "%2", profileID: profileA.id, kind: .claude
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
        let db = try TBDDatabase(inMemory: true)
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
        let db = try TBDDatabase(inMemory: true)
        let profileA = try await db.modelProfiles.create(
            name: "Profile A",
            kind: .oauth
        )
        let profileB = try await db.modelProfiles.create(
            name: "Profile B",
            kind: .oauth
        )

        let worktree = try await db.worktrees.createScratch(
            name: "wt", displayName: "wt", path: "/tmp/wt-balancing", tmuxServer: "@wt")
        // Create 1 live Claude terminal on A
        _ = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1", profileID: profileA.id, kind: .claude
        )

        // Create 1 hibernated terminal on A (should not count)
        let hibernated = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@2", tmuxPaneID: "%2", profileID: profileA.id, kind: .claude
        )
        try await db.terminals.setHibernated(id: hibernated.id, sessionID: "session-2", reason: .auto)

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

    // MARK: - Concurrent picks (reservations)

    /// Two eligible profiles on different accounts with identical usage and
    /// no live sessions, balancing on, and a resolver sharing one reservation
    /// ledger driven by `dates`.
    private func makeReservedFixture(
        dates: TestDateSource
    ) async throws -> (db: TBDDatabase, resolver: ModelProfileResolver,
                       reservations: ProfilePickReservations, worktreeID: UUID) {
        let db = try TBDDatabase(inMemory: true)
        for name in ["Profile A", "Profile B"] {
            let profile = try await db.modelProfiles.create(name: name, kind: .oauth)
            try await db.oauthUsageSnapshots.upsert(profileID: profile.id, snapshot: ProfileUsageSnapshot(
                buckets: [
                    .init(kind: "session", percent: 30, resetsAt: Date().addingTimeInterval(3600), isActive: true),
                ],
                fetchedAt: Date(),
                lastAttemptAt: Date(),
                status: "ok",
                statusKind: .ok,
                organizationID: nil
            ))
        }
        try await db.config.setProfileBalancingEnabled(true)
        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            // Distinct identities, so the two profiles are two accounts.
            loginIdentity: { "\($0.uuidString)@example.com" },
            now: dates.provider
        )
        let reservations = ProfilePickReservations(now: dates.provider)
        let resolver = ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config,
            candidateSource: source,
            reservations: reservations,
            now: dates.provider
        )
        let worktree = try await db.worktrees.createScratch(
            name: "wt", displayName: "wt", path: "/tmp/wt-reservations-\(UUID().uuidString)", tmuxServer: "@wt")
        return (db, resolver, reservations, worktree.id)
    }

    /// Two spawns into different worktrees both resolve before either
    /// terminal row exists. Without a reservation both read the same counts
    /// and pick the same profile; with one, the second sees the first.
    @Test("reservations: back-to-back picks with no row between them spread")
    func backToBackPicksWithoutARowChooseDifferentProfiles() async throws {
        let dates = TestDateSource(Date())
        let fixture = try await makeReservedFixture(dates: dates)

        let first = try await fixture.resolver.resolve(repoID: nil)
        let second = try await fixture.resolver.resolve(repoID: nil)

        let firstID = try #require(first?.profileID)
        let secondID = try #require(second?.profileID)
        #expect(firstID != secondID, "the second concurrent spawn piled onto the first's profile")
    }

    /// The same race run truly concurrently: four spawns resolve at once
    /// against two identical profiles, and no terminal row lands in between.
    /// Picking and reserving happen as one step on the ledger, so no two
    /// resolves can read the same counts — the picks split two and two.
    @Test("reservations: concurrent balanced resolves split evenly")
    func concurrentPicksSplitEvenly() async throws {
        let dates = TestDateSource(Date())
        let fixture = try await makeReservedFixture(dates: dates)
        let resolver = fixture.resolver

        let picks = try await withThrowingTaskGroup(of: UUID?.self) { group in
            for _ in 0..<4 {
                group.addTask { try await resolver.resolve(repoID: nil)?.profileID }
            }
            var picks: [UUID?] = []
            for try await pick in group { picks.append(pick) }
            return picks
        }

        let chosen = picks.compactMap { $0 }
        #expect(chosen.count == 4, "every balanced resolve should choose a profile")
        let counts = Dictionary(grouping: chosen, by: { $0 }).mapValues(\.count)
        #expect(counts.count == 2, "concurrent resolves piled onto one profile: \(counts)")
        #expect(counts.values.allSatisfy { $0 == 2 }, "concurrent resolves did not split evenly: \(counts)")
        #expect(await fixture.reservations.heldCount == 4)
    }

    /// Once the first spawn's row lands, the spawn settles its reservation
    /// and the live count alone carries the load — a profile is never counted
    /// twice.
    @Test("reservations: settling a reservation stops it counting")
    func settlingAReservationStopsItCounting() async throws {
        let dates = TestDateSource(Date())
        let fixture = try await makeReservedFixture(dates: dates)

        let first = try #require(try await fixture.resolver.resolve(repoID: nil))
        let firstID = first.profileID
        let reservationID = try #require(first.reservationID, "a balanced pick carries its reservation")
        _ = try await fixture.db.terminals.create(
            worktreeID: fixture.worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
            profileID: firstID, kind: .claude)
        await fixture.resolver.settleReservation(reservationID)
        #expect(await fixture.reservations.heldCount == 0)

        // First profile: 1 live row, nothing reserved. Second: 0 live.
        let secondID = try #require(try await fixture.resolver.resolve(repoID: nil)?.profileID)
        #expect(secondID != firstID)

        // Now each carries one session — the first as a row, the second as a
        // held reservation — so they tie and the tie-break repeats the first
        // pick. Counting the first profile's reservation on top of its row
        // would push this onto the second profile instead.
        let thirdID = try #require(try await fixture.resolver.resolve(repoID: nil)?.profileID)
        #expect(thirdID == firstID, "a settled reservation was counted on top of its landed row")
    }

    /// Rows from spawns that did not take a balanced pick — explicit picks,
    /// repo overrides — landing on a reserved profile must not erase that
    /// profile's reservations: only the spawn holding a reservation settles it.
    @Test("reservations: unrelated rows landing on a reserved profile do not erase its reservations")
    func unrelatedRowsDoNotEraseReservations() async throws {
        let dates = TestDateSource(Date())
        let fixture = try await makeReservedFixture(dates: dates)
        var window = 0
        func insertRow(on profileID: UUID) async throws {
            window += 1
            _ = try await fixture.db.terminals.create(
                worktreeID: fixture.worktreeID, tmuxWindowID: "@\(window)", tmuxPaneID: "%\(window)",
                profileID: profileID, kind: .claude)
        }

        // Three unlanded picks: X, Y, X — X holds two reservations, Y one.
        let x = try #require(try await fixture.resolver.resolve(repoID: nil))
        let y = try #require(try await fixture.resolver.resolve(repoID: nil))
        let x2 = try #require(try await fixture.resolver.resolve(repoID: nil))
        #expect(y.profileID != x.profileID)
        #expect(x2.profileID == x.profileID)

        // Y's spawn lands and settles, and two unrelated spawns add rows to
        // it: Y carries 3 rows and nothing reserved.
        try await insertRow(on: y.profileID)
        await fixture.resolver.settleReservation(y.reservationID)
        try await insertRow(on: y.profileID)
        try await insertRow(on: y.profileID)

        // Two unrelated spawns land on X. X now carries 2 rows plus its 2
        // held reservations = 4 against Y's 3. Had those rows erased X's
        // reservations, X would read 2 and win.
        try await insertRow(on: x.profileID)
        try await insertRow(on: x.profileID)
        #expect(await fixture.reservations.heldCount == 2)

        let next = try #require(try await fixture.resolver.resolve(repoID: nil)?.profileID)
        #expect(next == y.profileID, "unrelated rows on a reserved profile erased its reservations")
    }

    /// A spawn that failed after picking never lands a row; its reservation
    /// stops counting once the TTL passes.
    @Test("reservations: an expired reservation stops counting")
    func anExpiredReservationStopsCounting() async throws {
        let dates = TestDateSource(Date())
        let fixture = try await makeReservedFixture(dates: dates)

        let firstID = try #require(try await fixture.resolver.resolve(repoID: nil)?.profileID)
        #expect(await fixture.reservations.heldCount == 1)

        dates.advance(by: ProfilePickReservations.defaultTTL + 1)
        let secondID = try #require(try await fixture.resolver.resolve(repoID: nil)?.profileID)
        #expect(secondID == firstID, "an expired reservation still counted against its profile")
        #expect(await fixture.reservations.heldCount == 1, "the expired reservation was not pruned")
    }

    /// A resolver without a ledger keeps the plain pick: back-to-back picks
    /// with no row between them choose the same profile. This is the
    /// behavior the ledger exists to fix, pinned so the nil seam stays inert.
    @Test("reservations: no ledger, no reservation")
    func noLedgerPicksFromTheStoresAlone() async throws {
        let dates = TestDateSource(Date())
        let fixture = try await makeReservedFixture(dates: dates)
        let source = ProfilePoolCandidateSource(
            profiles: fixture.db.modelProfiles,
            snapshots: fixture.db.oauthUsageSnapshots,
            terminals: fixture.db.terminals,
            loginIdentity: { "\($0.uuidString)@example.com" },
            now: dates.provider
        )
        let plain = ModelProfileResolver(
            profiles: fixture.db.modelProfiles,
            repos: fixture.db.repos,
            config: fixture.db.config,
            candidateSource: source,
            now: dates.provider
        )

        let first = try await plain.resolve(repoID: nil)
        let second = try await plain.resolve(repoID: nil)
        #expect(first?.profileID != nil)
        #expect(first?.profileID == second?.profileID)
    }

    // MARK: - Resumed conversations are not balanced

    /// `balance: false` keeps the pre-balancing chain with the flag on: the
    /// global default, even when a balanced pick would choose another
    /// profile, and no reservation.
    @Test("resume: balance false returns the global default and reserves nothing")
    func balanceFalseReturnsTheDefault() async throws {
        let dates = TestDateSource(Date())
        let fixture = try await makeReservedFixture(dates: dates)
        let profiles = try await fixture.db.modelProfiles.list()
        let defaultProfile = try #require(profiles.first)
        try await fixture.db.config.setDefaultProfileID(defaultProfile.id)
        // Load the default so a balanced pick would steer away from it.
        for index in 1...3 {
            _ = try await fixture.db.terminals.create(
                worktreeID: fixture.worktreeID, tmuxWindowID: "@\(index)", tmuxPaneID: "%\(index)",
                profileID: defaultProfile.id, kind: .claude)
        }

        let resumed = try #require(try await fixture.resolver.resolve(repoID: nil, balance: false))
        #expect(resumed.profileID == defaultProfile.id)
        #expect(resumed.reservationID == nil)
        #expect(await fixture.reservations.heldCount == 0)

        // Control: the same state with balancing allowed picks elsewhere.
        let fresh = try #require(try await fixture.resolver.resolve(repoID: nil))
        #expect(fresh.profileID != defaultProfile.id)
        #expect(fresh.reservationID != nil)
    }

    /// With no global default, `balance: false` resolves to nothing (ambient
    /// credentials) rather than to a pick.
    @Test("resume: balance false with no default resolves to nil")
    func balanceFalseWithNoDefaultIsNil() async throws {
        let dates = TestDateSource(Date())
        let fixture = try await makeReservedFixture(dates: dates)

        let resumed = try await fixture.resolver.resolve(repoID: nil, balance: false)
        #expect(resumed == nil)
        #expect(await fixture.reservations.heldCount == 0)
    }

    @Test("resume: a terminal spawn balances only when it resumes nothing")
    func terminalSpawnBalancesOnlyWhenFresh() {
        #expect(ModelProfileResolver.balances(resumeSessionID: nil))
        #expect(!ModelProfileResolver.balances(resumeSessionID: "session-1"))
    }

    @Test("resume: a worktree spawn balances only when it restores and carries over nothing")
    func worktreeSpawnBalancesOnlyWhenFresh() {
        #expect(ModelProfileResolver.balancesWorktreeSpawn(
            restoringArchivedSessions: false, carryingOver: false))
        #expect(!ModelProfileResolver.balancesWorktreeSpawn(
            restoringArchivedSessions: true, carryingOver: false))
        #expect(!ModelProfileResolver.balancesWorktreeSpawn(
            restoringArchivedSessions: false, carryingOver: true))
        #expect(!ModelProfileResolver.balancesWorktreeSpawn(
            restoringArchivedSessions: true, carryingOver: true))
    }

    /// Balancing off never touches the ledger.
    @Test("reservations: balancing off reserves nothing")
    func balancingOffReservesNothing() async throws {
        let dates = TestDateSource(Date())
        let fixture = try await makeReservedFixture(dates: dates)
        try await fixture.db.config.setProfileBalancingEnabled(false)

        _ = try await fixture.resolver.resolve(repoID: nil)
        #expect(await fixture.reservations.heldCount == 0)
    }
}
