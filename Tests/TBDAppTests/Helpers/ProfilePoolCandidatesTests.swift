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
            organizationID: "org1",
            statusKind: .ok,
            isOK: true,
            buckets: [],
            fetchedAt: Date(),
            lastAttemptAt: Date()
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
            organizationID: nil,
            statusKind: .ok,
            isOK: true,
            buckets: [],
            fetchedAt: Date(),
            lastAttemptAt: Date()
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
            organizationID: nil,
            statusKind: .needsLogin,
            isOK: false,
            buckets: [],
            fetchedAt: Date(),
            lastAttemptAt: Date()
        )
        let entryNeedsLogin = ModelProfileWithUsage(profile: profile, usageSnapshot: needsLoginSnapshot)

        let candidateNeedsLogin = ProfilePoolCandidates.fromApp(
            entries: [entryNeedsLogin],
            liveCounts: { _ in 0 },
            defaultProfileID: nil
        ).first

        #expect(candidateNeedsLogin?.hasCredential == false)
    }
}
