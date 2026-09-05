import Foundation
import Testing
import TBDShared
@testable import TBDApp

struct AccountPickerOrderingTests {
    @Test
    func orderingOffEqualsSortedForPicker() {
        let profiles = [
            ModelProfileWithUsage(
                profile: ModelProfile(id: UUID(), name: "Profile A", kind: .oauth),
                loginIdentity: "a@example.com",
                usageSnapshot: ProfileUsageSnapshot(
                    organizationID: nil,
                    statusKind: .ok,
                    isOK: true,
                    buckets: [
                        ClaudeUsageLimitBucket(kind: "session", percent: 50, resetsAt: Date(), severity: nil, modelDisplayName: nil)
                    ],
                    fetchedAt: Date(),
                    lastAttemptAt: Date()
                )
            ),
            ModelProfileWithUsage(
                profile: ModelProfile(id: UUID(), name: "Profile B", kind: .oauth),
                loginIdentity: "b@example.com",
                usageSnapshot: ProfileUsageSnapshot(
                    organizationID: nil,
                    statusKind: .ok,
                    isOK: true,
                    buckets: [
                        ClaudeUsageLimitBucket(kind: "session", percent: 30, resetsAt: Date(), severity: nil, modelDisplayName: nil)
                    ],
                    fetchedAt: Date(),
                    lastAttemptAt: Date()
                )
            )
        ]

        let result = AccountPickerOrdering.order(
            entries: profiles,
            balancingOn: false,
            liveCount: { _ in 0 },
            defaultProfileID: nil,
            now: Date()
        )

        let displayOrder = ProfileUsagePresentation.sortedForPicker(profiles)
        #expect(result.ordered == displayOrder)
        #expect(result.balancedPickID == nil)
    }

    @Test
    func orderingOnHasEligibleRowsFirst() {
        let oauthID = UUID()
        let bedrockID = UUID()

        let profiles = [
            ModelProfileWithUsage(
                profile: ModelProfile(id: oauthID, name: "OAuth", kind: .oauth),
                loginIdentity: "user@example.com",
                usageSnapshot: ProfileUsageSnapshot(
                    organizationID: nil,
                    statusKind: .ok,
                    isOK: true,
                    buckets: [
                        ClaudeUsageLimitBucket(kind: "session", percent: 40, resetsAt: Date(), severity: nil, modelDisplayName: nil)
                    ],
                    fetchedAt: Date(),
                    lastAttemptAt: Date()
                )
            ),
            ModelProfileWithUsage(
                profile: ModelProfile(id: bedrockID, name: "Bedrock", kind: .bedrock)
            )
        ]

        let result = AccountPickerOrdering.order(
            entries: profiles,
            balancingOn: true,
            liveCount: { _ in 0 },
            defaultProfileID: nil,
            now: Date()
        )

        // OAuth (eligible) should be first
        #expect(result.ordered.first?.profile.id == oauthID)
        // Bedrock (ineligible) should be second
        #expect(result.ordered.last?.profile.id == bedrockID)
        // balancedPickID should be the first eligible (OAuth)
        #expect(result.balancedPickID == oauthID)
    }

    @Test
    func orderingOnPreservesAllRows() {
        let oauthID = UUID()
        let apiKeyID = UUID()
        let bedrockID = UUID()

        let profiles = [
            ModelProfileWithUsage(
                profile: ModelProfile(id: oauthID, name: "OAuth", kind: .oauth),
                loginIdentity: "user@example.com",
                usageSnapshot: ProfileUsageSnapshot(
                    organizationID: nil,
                    statusKind: .ok,
                    isOK: true,
                    buckets: [
                        ClaudeUsageLimitBucket(kind: "session", percent: 30, resetsAt: Date(), severity: nil, modelDisplayName: nil)
                    ],
                    fetchedAt: Date(),
                    lastAttemptAt: Date()
                )
            ),
            ModelProfileWithUsage(
                profile: ModelProfile(id: apiKeyID, name: "API Key", kind: .apiKey)
            ),
            ModelProfileWithUsage(
                profile: ModelProfile(id: bedrockID, name: "Bedrock", kind: .bedrock)
            )
        ]

        let result = AccountPickerOrdering.order(
            entries: profiles,
            balancingOn: true,
            liveCount: { _ in 0 },
            defaultProfileID: nil,
            now: Date()
        )

        // All three profiles must be present
        #expect(result.ordered.count == 3)
        let ids = Set(result.ordered.map { $0.profile.id })
        #expect(ids.contains(oauthID))
        #expect(ids.contains(apiKeyID))
        #expect(ids.contains(bedrockID))
    }

    @Test
    func balancedPickIDIsNilWhenBalancingOff() {
        let profiles = [
            ModelProfileWithUsage(
                profile: ModelProfile(id: UUID(), name: "Profile", kind: .oauth),
                loginIdentity: "user@example.com"
            )
        ]

        let result = AccountPickerOrdering.order(
            entries: profiles,
            balancingOn: false,
            liveCount: { _ in 0 },
            defaultProfileID: nil,
            now: Date()
        )

        #expect(result.balancedPickID == nil)
    }

    @Test
    func balancedPickIDIsNilWhenNoEligibleProfiles() {
        let profiles = [
            ModelProfileWithUsage(
                profile: ModelProfile(id: UUID(), name: "Bedrock", kind: .bedrock)
            ),
            ModelProfileWithUsage(
                profile: ModelProfile(id: UUID(), name: "API Key", kind: .apiKey)
            )
        ]

        let result = AccountPickerOrdering.order(
            entries: profiles,
            balancingOn: true,
            liveCount: { _ in 0 },
            defaultProfileID: nil,
            now: Date()
        )

        // No eligible profiles, so balancedPickID should be nil
        #expect(result.balancedPickID == nil)
    }
}
