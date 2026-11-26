import Foundation
import Testing
import TBDShared
@testable import TBDApp

struct AccountPickerOrderingTests {
    private func entry(id: UUID, name: String, percent: Double, now: Date) -> ModelProfileWithUsage {
        ModelProfileWithUsage(
            profile: ModelProfile(id: id, name: name, kind: .oauth),
            loginIdentity: "\(name)@example.com",
            usageSnapshot: ProfileUsageSnapshot(
                buckets: [ClaudeUsageLimitBucket(kind: "session", percent: percent)],
                fetchedAt: now,
                lastAttemptAt: now,
                status: "ok",
                statusKind: .ok,
                organizationID: nil))
    }

    private func sessionEntry(name: String, percent: Double, resetsAt: Date,
                              now: Date) -> ModelProfileWithUsage {
        ModelProfileWithUsage(
            profile: ModelProfile(id: UUID(), name: name, kind: .oauth),
            loginIdentity: "\(name)@example.com",
            usageSnapshot: ProfileUsageSnapshot(
                buckets: [ClaudeUsageLimitBucket(kind: "session", percent: percent, resetsAt: resetsAt)],
                fetchedAt: now,
                lastAttemptAt: now,
                status: "ok",
                statusKind: .ok,
                organizationID: nil))
    }

    /// With balancing off the rows follow `sortedForPicker` at the time the
    /// sheet passes: a 5h window that has reset ranks as a fresh 0% one.
    @Test
    func orderingOffRanksAnEndedSessionWindowAsFresh() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let spent = sessionEntry(name: "Spent", percent: 95,
                                 resetsAt: now.addingTimeInterval(-60), now: now)
        let busy = sessionEntry(name: "Busy", percent: 20,
                                resetsAt: now.addingTimeInterval(3600), now: now)

        let afterReset = AccountPickerOrdering.order(
            entries: [busy, spent], balancingOn: false, liveCount: { _ in 0 },
            defaultProfileID: nil, now: now)
        #expect(afterReset.ordered.map(\.profile.name) == ["Spent", "Busy"])

        let beforeReset = AccountPickerOrdering.order(
            entries: [spent, busy], balancingOn: false, liveCount: { _ in 0 },
            defaultProfileID: nil, now: now.addingTimeInterval(-3600))
        #expect(beforeReset.ordered.map(\.profile.name) == ["Busy", "Spent"])
    }

    /// With balancing on, the sheet marks the daemon's pick, and the daemon
    /// ranks an account by the percent it last recorded: a profile whose 5h
    /// window reset after a 95% reading stays over the ceiling until its next
    /// reading, though its bar already shows a fresh window. The rows the
    /// balancer turns away follow the sheet's own order (`sortedForPicker`),
    /// which counts that ended window as 0%.
    @Test
    func balancedPickKeepsTheRecordedPercentOfAnEndedSessionWindow() {
        let resetAt = Date(timeIntervalSince1970: 1_800_000_000)
        // All read a minute before Spent's 5h reset, inside the staleness
        // window at every instant below.
        let readAt = resetAt.addingTimeInterval(-60)
        let spent = sessionEntry(name: "Spent", percent: 95, resetsAt: resetAt, now: readAt)
        let full = sessionEntry(name: "Full", percent: 90,
                                resetsAt: resetAt.addingTimeInterval(4 * 3600), now: readAt)
        let busy = sessionEntry(name: "Busy", percent: 20,
                                resetsAt: resetAt.addingTimeInterval(4 * 3600), now: readAt)

        let beforeReset = AccountPickerOrdering.order(
            entries: [spent, full, busy], balancingOn: true, liveCount: { _ in 0 },
            defaultProfileID: nil, now: resetAt.addingTimeInterval(-30))
        #expect(beforeReset.balancedPickID == busy.profile.id)
        #expect(beforeReset.ordered.map(\.profile.name) == ["Busy", "Full", "Spent"])

        for now in [resetAt, resetAt.addingTimeInterval(60)] {
            let afterReset = AccountPickerOrdering.order(
                entries: [full, spent, busy], balancingOn: true, liveCount: { _ in 0 },
                defaultProfileID: nil, now: now)
            #expect(afterReset.balancedPickID == busy.profile.id)
            #expect(afterReset.ordered.map(\.profile.name) == ["Busy", "Spent", "Full"])
        }
    }

    /// The sheet marks the daemon's pick under the daemon's thresholds: a
    /// profile at 90% is no balanced pick under the shipped 85% ceiling, and is
    /// one under a 95% ceiling.
    @Test
    func balancedPickFollowsTheDaemonsUsageCeiling() {
        let now = Date()
        let busyID = UUID()
        let entries = [entry(id: busyID, name: "Busy", percent: 90, now: now)]

        let shipped = AccountPickerOrdering.order(
            entries: entries, balancingOn: true, liveCount: { _ in 0 },
            defaultProfileID: nil, now: now)
        #expect(shipped.balancedPickID == nil)

        let raised = AccountPickerOrdering.order(
            entries: entries, balancingOn: true, liveCount: { _ in 0 },
            defaultProfileID: nil, now: now,
            policy: ProfilePoolPolicy(usageCeilingPercent: 95))
        #expect(raised.balancedPickID == busyID)
    }

    @Test
    func orderingOffEqualsSortedForPicker() {
        let profiles = [
            ModelProfileWithUsage(
                profile: ModelProfile(id: UUID(), name: "Profile A", kind: .oauth),
                loginIdentity: "a@example.com",
                usageSnapshot: ProfileUsageSnapshot(
                buckets: [
                        ClaudeUsageLimitBucket(kind: "session", percent: 50, severity: nil, resetsAt: Date(), modelDisplayName: nil)
                    ],
                fetchedAt: Date(),
                lastAttemptAt: Date(),
                status: "ok",
                statusKind: .ok,
                organizationID: nil
                )
            ),
            ModelProfileWithUsage(
                profile: ModelProfile(id: UUID(), name: "Profile B", kind: .oauth),
                loginIdentity: "b@example.com",
                usageSnapshot: ProfileUsageSnapshot(
                buckets: [
                        ClaudeUsageLimitBucket(kind: "session", percent: 30, severity: nil, resetsAt: Date(), modelDisplayName: nil)
                    ],
                fetchedAt: Date(),
                lastAttemptAt: Date(),
                status: "ok",
                statusKind: .ok,
                organizationID: nil
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
                buckets: [
                        ClaudeUsageLimitBucket(kind: "session", percent: 40, severity: nil, resetsAt: Date(), modelDisplayName: nil)
                    ],
                fetchedAt: Date(),
                lastAttemptAt: Date(),
                status: "ok",
                statusKind: .ok,
                organizationID: nil
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
                buckets: [
                        ClaudeUsageLimitBucket(kind: "session", percent: 30, severity: nil, resetsAt: Date(), modelDisplayName: nil)
                    ],
                fetchedAt: Date(),
                lastAttemptAt: Date(),
                status: "ok",
                statusKind: .ok,
                organizationID: nil
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
