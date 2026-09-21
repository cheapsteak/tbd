import Foundation
import Testing
import TBDShared
@testable import TBDApp

struct LimitBannerModelTests {
    @Test
    func buildsModelWithSuggestedProfile() {
        let now = Date()
        let resetTime = now.addingTimeInterval(3600) // 1 hour from now
        let limitHit = TerminalLimitHit(
            profileID: UUID(),
            resetsAt: resetTime,
            limitType: "session",
            suggestedProfileID: UUID(),
            receivedAt: now
        )

        let limitedProfile = ModelProfileWithUsage(
            profile: ModelProfile(id: limitHit.profileID!, name: "Limited", kind: .oauth),
            loginIdentity: "user@example.com"
        )

        let suggestedProfile = ModelProfileWithUsage(
            profile: ModelProfile(id: limitHit.suggestedProfileID!, name: "Available", kind: .oauth),
            loginIdentity: "user2@example.com",
            usageSnapshot: ProfileUsageSnapshot(
                buckets: [
                    ClaudeUsageLimitBucket(
                        kind: "session",
                        percent: 30,
                        severity: nil,
                        resetsAt: resetTime,
                        modelDisplayName: nil
                    )
                ],
                fetchedAt: now,
                lastAttemptAt: now,
                status: "ok",
                statusKind: .ok,
                organizationID: nil
            ),
            liveSessions: 2
        )

        let model = LimitBannerModel.build(
            limitHit: limitHit,
            limitedProfile: limitedProfile,
            suggestedProfile: suggestedProfile,
            suggestedLiveCount: 2,
            now: now
        )

        #expect(model.limitedProfileName == "Limited")
        #expect(model.suggestedProfileName == "Available")
        #expect(model.suggestedLiveSessions == 2)
        #expect(model.suggestedUsageSummary?.contains("30") == true) // Usage percent
        #expect(model.suggestedUsageSummary?.contains("live") == true)
        #expect(model.switchButtonTitle?.hasPrefix("Switch to Available — ") == true)
    }

    @Test
    func buildsModelWithoutSuggestedProfile() {
        let now = Date()
        let resetTime = now.addingTimeInterval(7200)
        let limitHit = TerminalLimitHit(
            profileID: UUID(),
            resetsAt: resetTime,
            limitType: "session",
            suggestedProfileID: nil,
            receivedAt: now
        )

        let limitedProfile = ModelProfileWithUsage(
            profile: ModelProfile(id: limitHit.profileID!, name: "OnlyProfile", kind: .oauth)
        )

        let model = LimitBannerModel.build(
            limitHit: limitHit,
            limitedProfile: limitedProfile,
            suggestedProfile: nil,
            suggestedLiveCount: nil,
            now: now
        )

        #expect(model.limitedProfileName == "OnlyProfile")
        #expect(model.suggestedProfileName == nil)
        #expect(model.suggestedUsageSummary == nil)
        #expect(model.switchButtonTitle == nil)
    }

    /// A suggestion whose fresh snapshot has no displayable buckets and no
    /// live sessions has nothing to summarize: the summary is nil, not "",
    /// so the button reads "Switch to X" with no dangling em-dash.
    @Test
    func emptySummaryIsNilNotEmptyString() {
        let now = Date()
        let limitHit = TerminalLimitHit(
            profileID: UUID(),
            resetsAt: now.addingTimeInterval(3600),
            limitType: "session",
            suggestedProfileID: UUID(),
            receivedAt: now
        )
        let suggestedProfile = ModelProfileWithUsage(
            profile: ModelProfile(id: limitHit.suggestedProfileID!, name: "Spare", kind: .oauth),
            usageSnapshot: ProfileUsageSnapshot(
                buckets: [],
                fetchedAt: now,
                lastAttemptAt: now,
                status: "ok",
                statusKind: .ok,
                organizationID: nil
            ),
            liveSessions: 0
        )

        let model = LimitBannerModel.build(
            limitHit: limitHit,
            limitedProfile: nil,
            suggestedProfile: suggestedProfile,
            suggestedLiveCount: 0,
            now: now
        )

        #expect(model.suggestedProfileName == "Spare")
        #expect(model.suggestedUsageSummary == nil)
        #expect(model.switchButtonTitle == "Switch to Spare")
    }

    /// Live sessions alone still make a summary, without a leading separator.
    @Test
    func liveCountAloneIsTheSummary() {
        let now = Date()
        let limitHit = TerminalLimitHit(
            profileID: UUID(),
            resetsAt: now.addingTimeInterval(3600),
            limitType: "session",
            suggestedProfileID: UUID(),
            receivedAt: now
        )
        let suggestedProfile = ModelProfileWithUsage(
            profile: ModelProfile(id: limitHit.suggestedProfileID!, name: "Spare", kind: .oauth)
        )

        let model = LimitBannerModel.build(
            limitHit: limitHit,
            limitedProfile: nil,
            suggestedProfile: suggestedProfile,
            suggestedLiveCount: 3,
            now: now
        )

        #expect(model.suggestedUsageSummary == "3 live")
        #expect(model.switchButtonTitle == "Switch to Spare — 3 live")
    }
}
