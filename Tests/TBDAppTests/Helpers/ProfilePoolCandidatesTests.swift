import Foundation
import Testing
import TBDShared
@testable import TBDApp

struct ProfilePoolCandidatesTests {
    @Test
    func buildsCandidatesFromAppState() {
        let profile1 = ModelProfile(
            id: UUID(),
            name: "Profile 1",
            kind: .oauth,
            poolOptOut: false
        )
        let profile2 = ModelProfile(
            id: UUID(),
            name: "Profile 2",
            kind: .oauthToken,
            poolOptOut: true
        )

        let snapshot1 = ProfileUsageSnapshot(
            buckets: [],
            fetchedAt: Date(),
            lastAttemptAt: Date(),
            status: "ok",
            statusKind: .ok,
            organizationID: "org1"
        )

        let entry1 = ModelProfileWithUsage(
            profile: profile1,
            loginIdentity: "user1@example.com",
            usageSnapshot: snapshot1,
            liveSessions: 5
        )
        let entry2 = ModelProfileWithUsage(
            profile: profile2,
            usageSnapshot: nil,
            liveSessions: 2
        )

        let entries = [entry1, entry2]
        let liveCounts: (UUID) -> Int = { id in
            return id == profile1.id ? 3 : 1
        }
        let defaultID = profile1.id

        let candidates = ProfilePoolCandidates.fromApp(
            entries: entries,
            liveCounts: liveCounts,
            defaultProfileID: defaultID
        )

        #expect(candidates.count == 2)

        let cand1 = candidates.first { $0.profileID == profile1.id }
        #expect(cand1 != nil)
        #expect(cand1?.kind == .oauth)
        #expect(cand1?.hasCredential == true)
        #expect(cand1?.poolOptOut == false)
        #expect(cand1?.liveSessions == 3)
        #expect(cand1?.accountKey == "org1") // organizationID takes precedence
        #expect(cand1?.isConfiguredDefault == true)

        let cand2 = candidates.first { $0.profileID == profile2.id }
        #expect(cand2 != nil)
        #expect(cand2?.kind == .oauthToken)
        #expect(cand2?.poolOptOut == true)
        #expect(cand2?.liveSessions == 1)
        #expect(cand2?.accountKey == profile2.id.uuidString) // Falls back to profile ID
    }

    @Test
    func oauthTokenCredentialDetection() {
        let profile = ModelProfile(
            id: UUID(),
            name: "Token Profile",
            kind: .oauthToken
        )

        // With OK snapshot: has credential
        let okSnapshot = ProfileUsageSnapshot(
            buckets: [],
            fetchedAt: Date(),
            lastAttemptAt: Date(),
            status: "ok",
            statusKind: .ok,
            organizationID: nil
        )
        let entryOK = ModelProfileWithUsage(profile: profile, usageSnapshot: okSnapshot)

        let candidateOK = ProfilePoolCandidates.fromApp(
            entries: [entryOK],
            liveCounts: { _ in 0 },
            defaultProfileID: nil
        ).first

        #expect(candidateOK?.hasCredential == true)

        // With needsLogin snapshot: no credential
        let needsLoginSnapshot = ProfileUsageSnapshot(
            buckets: [],
            fetchedAt: Date(),
            lastAttemptAt: Date(),
            status: "needs login",
            statusKind: .needsLogin,
            organizationID: nil
        )
        let entryNeedsLogin = ModelProfileWithUsage(profile: profile, usageSnapshot: needsLoginSnapshot)

        let candidateNeedsLogin = ProfilePoolCandidates.fromApp(
            entries: [entryNeedsLogin],
            liveCounts: { _ in 0 },
            defaultProfileID: nil
        ).first

        #expect(candidateNeedsLogin?.hasCredential == false)

        // With no snapshot yet: the stored token counts, matching the daemon's
        // candidate source (the picker still rejects it as .noFreshReading).
        let entryUnprobed = ModelProfileWithUsage(profile: profile, usageSnapshot: nil)

        let candidateUnprobed = ProfilePoolCandidates.fromApp(
            entries: [entryUnprobed],
            liveCounts: { _ in 0 },
            defaultProfileID: nil
        ).first

        #expect(candidateUnprobed?.hasCredential == true)
        if let candidateUnprobed {
            let decision = ProfilePoolPicker.pick(candidates: [candidateUnprobed], now: Date())
            #expect(decision.chosen == nil)
            #expect(decision.verdicts[profile.id] == .noFreshReading)
        }
    }

    // MARK: - Stale badge (design 2026-09-05 §6.1)

    @Test
    func staleBadgeShowsOnlyForNoFreshReadingWhileBalancingIsOn() {
        #expect(ProfilePoolCandidates.showsStaleBadge(balancingOn: true, verdict: .noFreshReading))
        #expect(!ProfilePoolCandidates.showsStaleBadge(balancingOn: false, verdict: .noFreshReading))
        let others: [ProfilePoolVerdict?] = [
            .optedOut, .wrongKind, .noCredential, .exhausted, .sameAccount,
            .eligible(score: 1, headroom: 0.5, accountLiveSessions: 0), nil,
        ]
        for verdict in others {
            #expect(!ProfilePoolCandidates.showsStaleBadge(balancingOn: true, verdict: verdict))
        }
    }

    @Test
    func staleBadgeProfileIDsUsesThePickersVerdicts() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func snapshot(ageMinutes: Double, percent: Double = 10) -> ProfileUsageSnapshot {
            ProfileUsageSnapshot(
                buckets: [ClaudeUsageLimitBucket(kind: "session", group: "session", percent: percent)],
                fetchedAt: now.addingTimeInterval(-ageMinutes * 60),
                lastAttemptAt: now, status: "ok", statusKind: .ok)
        }
        let stale = ModelProfileWithUsage(
            profile: ModelProfile(id: UUID(), name: "Stale", kind: .oauth),
            loginIdentity: "a@example.com", usageSnapshot: snapshot(ageMinutes: 42))
        let neverRead = ModelProfileWithUsage(
            profile: ModelProfile(id: UUID(), name: "NeverRead", kind: .oauth),
            loginIdentity: "b@example.com")
        let fresh = ModelProfileWithUsage(
            profile: ModelProfile(id: UUID(), name: "Fresh", kind: .oauth),
            loginIdentity: "c@example.com", usageSnapshot: snapshot(ageMinutes: 1))
        let exhausted = ModelProfileWithUsage(
            profile: ModelProfile(id: UUID(), name: "Full", kind: .oauth),
            loginIdentity: "d@example.com", usageSnapshot: snapshot(ageMinutes: 1, percent: 99))
        let optedOut = ModelProfileWithUsage(
            profile: ModelProfile(id: UUID(), name: "Out", kind: .oauth, poolOptOut: true),
            loginIdentity: "e@example.com", usageSnapshot: snapshot(ageMinutes: 42))
        let noCredential = ModelProfileWithUsage(
            profile: ModelProfile(id: UUID(), name: "NoLogin", kind: .oauth),
            usageSnapshot: snapshot(ageMinutes: 42))
        let wrongKind = ModelProfileWithUsage(
            profile: ModelProfile(id: UUID(), name: "Bedrock", kind: .bedrock))
        let entries = [stale, neverRead, fresh, exhausted, optedOut, noCredential, wrongKind]

        let on = ProfilePoolCandidates.staleBadgeProfileIDs(
            entries: entries, balancingOn: true, defaultProfileID: nil, now: now)
        #expect(on == [stale.profile.id, neverRead.profile.id])

        let off = ProfilePoolCandidates.staleBadgeProfileIDs(
            entries: entries, balancingOn: false, defaultProfileID: nil, now: now)
        #expect(off.isEmpty)
    }
}
