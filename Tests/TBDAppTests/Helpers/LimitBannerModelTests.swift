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
            rotatedToProfileID: nil,
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
                organizationID: nil,
                statusKind: .ok,
                isOK: true,
                buckets: [
                    ClaudeUsageLimitBucket(
                        kind: "session",
                        percent: 30,
                        resetsAt: resetTime,
                        severity: nil,
                        modelDisplayName: nil
                    )
                ],
                fetchedAt: now,
                lastAttemptAt: now
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
        #expect(model.isRotated == false)
        #expect(model.suggestedUsageSummary?.contains("30") == true) // Usage percent
        #expect(model.suggestedUsageSummary?.contains("live") == true)
    }

    @Test
    func buildsModelForRotatedSession() {
        let now = Date()
        let resetTime = now.addingTimeInterval(1800)
        let limitHit = TerminalLimitHit(
            profileID: UUID(),
            resetsAt: resetTime,
            limitType: "weekly_all",
            suggestedProfileID: UUID(),
            rotatedToProfileID: UUID(),
            receivedAt: now
        )

        let model = LimitBannerModel.build(
            limitHit: limitHit,
            limitedProfile: nil,
            suggestedProfile: nil,
            suggestedLiveCount: nil,
            now: now
        )

        #expect(model.limitedProfileName == "this account")
        #expect(model.isRotated == true)
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
            rotatedToProfileID: nil,
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
    }
}
