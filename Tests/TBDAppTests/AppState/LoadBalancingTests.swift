import Foundation
import Testing
import TBDShared
@testable import TBDApp

struct LoadBalancingTests {
    // MARK: - Ordering Tests

    @Test
    func orderingWithBalancingOffEqualsDisplayOrder() {
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
                profile: ModelProfile(id: UUID(), name: "Profile B", kind: .bedrock)
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
    func orderingWithBalancingOnIsEligibleFirst() {
        let profileID1 = UUID()
        let profileID2 = UUID()
        let profileID3 = UUID()

        let profiles = [
            ModelProfileWithUsage(
                profile: ModelProfile(id: profileID1, name: "OAuth", kind: .oauth, poolOptOut: false),
                loginIdentity: "user@example.com",
                usageSnapshot: ProfileUsageSnapshot(
                    organizationID: nil,
                    statusKind: .ok,
                    isOK: true,
                    buckets: [
                        ClaudeUsageLimitBucket(kind: "session", percent: 20, resetsAt: Date(), severity: nil, modelDisplayName: nil)
                    ],
                    fetchedAt: Date(),
                    lastAttemptAt: Date()
                )
            ),
            ModelProfileWithUsage(
                profile: ModelProfile(id: profileID2, name: "Bedrock", kind: .bedrock)
            ),
            ModelProfileWithUsage(
                profile: ModelProfile(id: profileID3, name: "API Key", kind: .apiKey)
            )
        ]

        let result = AccountPickerOrdering.order(
            entries: profiles,
            balancingOn: true,
            liveCount: { _ in 0 },
            defaultProfileID: nil,
            now: Date()
        )

        // OAuth should be first (eligible), then the rest in display order
        #expect(result.ordered.first?.profile.id == profileID1)
        #expect(result.ordered.count == 3)
        #expect(result.balancedPickID == profileID1)
    }

    @Test
    func orderingPreservesIneligibleRows() {
        let oauthID = UUID()
        let bedrockID = UUID()
        let apikeyID = UUID()

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
                profile: ModelProfile(id: bedrockID, name: "Bedrock", kind: .bedrock)
            ),
            ModelProfileWithUsage(
                profile: ModelProfile(id: apikeyID, name: "API Key", kind: .apiKey)
            )
        ]

        let result = AccountPickerOrdering.order(
            entries: profiles,
            balancingOn: true,
            liveCount: { _ in 0 },
            defaultProfileID: nil,
            now: Date()
        )

        // All profiles should be present
        #expect(result.ordered.count == 3)
        let ids = Set(result.ordered.map { $0.profile.id })
        #expect(ids.contains(oauthID))
        #expect(ids.contains(bedrockID))
        #expect(ids.contains(apikeyID))
    }

    // MARK: - Live Session Count Tests

    @Test
    func liveSessionCountPrefersDeamonValue() async {
        let appState = AppState(
            userDefaults: UserDefaults(suiteName: "test.lb.daemon-count")!,
            modelProfilesFetcher: { try await AppState.defaultModelProfilesFetcher() },
            daemonCapabilitiesFetcher: { try await AppState.defaultDaemonCapabilitiesFetcher() },
            daemonClient: DaemonClientDouble(),
            profileBalancingFlagSetter: { _ in },
            limitRotationFlagSetter: { _ in },
            profilePoolOptOutSetter: { _, _ in }
        )

        let profileID = UUID()
        appState.modelProfiles = [
            ModelProfileWithUsage(
                profile: ModelProfile(id: profileID, name: "Test", kind: .oauth),
                liveSessions: 5
            )
        ]

        #expect(appState.liveSessionCount(forProfile: profileID) == 5)
    }

    @Test
    func liveSessionCountCountsUnparkedClaudeSessions() async {
        let appState = AppState(
            userDefaults: UserDefaults(suiteName: "test.lb.local-count")!,
            modelProfilesFetcher: { try await AppState.defaultModelProfilesFetcher() },
            daemonCapabilitiesFetcher: { try await AppState.defaultDaemonCapabilitiesFetcher() },
            daemonClient: DaemonClientDouble(),
            profileBalancingFlagSetter: { _ in },
            limitRotationFlagSetter: { _ in },
            profilePoolOptOutSetter: { _, _ in }
        )

        let profileID = UUID()
        let worktreeID = UUID()
        appState.modelProfiles = [
            ModelProfileWithUsage(
                profile: ModelProfile(id: profileID, name: "Test", kind: .oauth),
                liveSessions: nil
            )
        ]

        // Add a mix of terminals
        appState.terminals[worktreeID] = [
            Terminal(id: UUID(), worktreeID: worktreeID, kind: .claude, profileID: profileID, hibernatedAt: nil, suspendedAt: nil), // Counts
            Terminal(id: UUID(), worktreeID: worktreeID, kind: .claude, profileID: profileID, hibernatedAt: Date(), suspendedAt: nil), // Parked, doesn't count
            Terminal(id: UUID(), worktreeID: worktreeID, kind: .claude, profileID: UUID(), hibernatedAt: nil, suspendedAt: nil), // Different profile
            Terminal(id: UUID(), worktreeID: worktreeID, kind: .shell, profileID: profileID, hibernatedAt: nil, suspendedAt: nil) // Not Claude
        ]

        #expect(appState.liveSessionCount(forProfile: profileID) == 1)
    }

    // MARK: - Limit Hits Lifecycle Tests

    @Test
    func limitHitsSetByDelta() async {
        let appState = AppState(
            userDefaults: UserDefaults(suiteName: "test.lb.limit-set")!,
            modelProfilesFetcher: { try await AppState.defaultModelProfilesFetcher() },
            daemonCapabilitiesFetcher: { try await AppState.defaultDaemonCapabilitiesFetcher() },
            daemonClient: DaemonClientDouble(),
            profileBalancingFlagSetter: { _ in },
            limitRotationFlagSetter: { _ in },
            profilePoolOptOutSetter: { _, _ in }
        )

        let terminalID = UUID()
        let delta = TerminalLimitHitDelta(
            terminalID: terminalID,
            worktreeID: UUID(),
            profileID: UUID(),
            resetsAt: Date(),
            limitType: "session"
        )

        appState.handleDelta(.terminalLimitHit(delta))

        #expect(appState.limitHits[terminalID] != nil)
        #expect(appState.limitHits[terminalID]?.limitType == "session")
    }

    @Test
    func limitHitsClearedOnWorkingActivity() async {
        let appState = AppState(
            userDefaults: UserDefaults(suiteName: "test.lb.limit-clear-working")!,
            modelProfilesFetcher: { try await AppState.defaultModelProfilesFetcher() },
            daemonCapabilitiesFetcher: { try await AppState.defaultDaemonCapabilitiesFetcher() },
            daemonClient: DaemonClientDouble(),
            profileBalancingFlagSetter: { _ in },
            limitRotationFlagSetter: { _ in },
            profilePoolOptOutSetter: { _, _ in }
        )

        let terminalID = UUID()
        let worktreeID = UUID()

        appState.limitHits[terminalID] = TerminalLimitHit(
            profileID: UUID(),
            resetsAt: Date(),
            limitType: "session",
            suggestedProfileID: nil,
            rotatedToProfileID: nil,
            receivedAt: Date()
        )

        appState.terminals[worktreeID] = [
            Terminal(id: terminalID, worktreeID: worktreeID, kind: .claude, activityState: .idle)
        ]

        appState.applyTerminalActivityDelta(
            TerminalActivityDelta(terminalID: terminalID, worktreeID: worktreeID, activityState: .working)
        )

        #expect(appState.limitHits[terminalID] == nil)
    }

    @Test
    func limitHitsClearedOnProfileChange() async {
        let appState = AppState(
            userDefaults: UserDefaults(suiteName: "test.lb.limit-clear-profile")!,
            modelProfilesFetcher: { try await AppState.defaultModelProfilesFetcher() },
            daemonCapabilitiesFetcher: { try await AppState.defaultDaemonCapabilitiesFetcher() },
            daemonClient: DaemonClientDouble(),
            profileBalancingFlagSetter: { _ in },
            limitRotationFlagSetter: { _ in },
            profilePoolOptOutSetter: { _, _ in }
        )

        let terminalID = UUID()
        let worktreeID = UUID()

        appState.limitHits[terminalID] = TerminalLimitHit(
            profileID: UUID(),
            resetsAt: Date(),
            limitType: "session",
            suggestedProfileID: nil,
            rotatedToProfileID: nil,
            receivedAt: Date()
        )

        appState.terminals[worktreeID] = [
            Terminal(id: terminalID, worktreeID: worktreeID, kind: .claude, profileID: UUID())
        ]

        appState.applyTerminalProfileDelta(
            TerminalProfileDelta(terminalID: terminalID, worktreeID: worktreeID, newProfileID: UUID())
        )

        #expect(appState.limitHits[terminalID] == nil)
    }

    // MARK: - Flag Setter Tests

    @Test
    func profileBalancingSetterCallsClosureAndRefreshes() async {
        var setterCalled = false
        var capabilitiesRefreshed = false

        let appState = AppState(
            userDefaults: UserDefaults(suiteName: "test.lb.balancing-setter")!,
            modelProfilesFetcher: { try await AppState.defaultModelProfilesFetcher() },
            daemonCapabilitiesFetcher: {
                capabilitiesRefreshed = true
                return try await AppState.defaultDaemonCapabilitiesFetcher()
            },
            daemonClient: DaemonClientDouble(),
            profileBalancingFlagSetter: { _ in setterCalled = true },
            limitRotationFlagSetter: { _ in },
            profilePoolOptOutSetter: { _, _ in }
        )

        await appState.setProfileBalancingEnabled(true)

        #expect(setterCalled)
        #expect(capabilitiesRefreshed)
    }

    @Test
    func limitRotationSetterCallsClosureAndRefreshes() async {
        var setterCalled = false
        var capabilitiesRefreshed = false

        let appState = AppState(
            userDefaults: UserDefaults(suiteName: "test.lb.rotation-setter")!,
            modelProfilesFetcher: { try await AppState.defaultModelProfilesFetcher() },
            daemonCapabilitiesFetcher: {
                capabilitiesRefreshed = true
                return try await AppState.defaultDaemonCapabilitiesFetcher()
            },
            daemonClient: DaemonClientDouble(),
            profileBalancingFlagSetter: { _ in },
            limitRotationFlagSetter: { _ in setterCalled = true },
            profilePoolOptOutSetter: { _, _ in }
        )

        await appState.setLimitRotationEnabled(true)

        #expect(setterCalled)
        #expect(capabilitiesRefreshed)
    }

    @Test
    func poolOptOutSetterCallsClosureAndReloads() async {
        var setterCalled = false
        var profilesReloaded = false

        let appState = AppState(
            userDefaults: UserDefaults(suiteName: "test.lb.opt-out-setter")!,
            modelProfilesFetcher: {
                profilesReloaded = true
                return try await AppState.defaultModelProfilesFetcher()
            },
            daemonCapabilitiesFetcher: { try await AppState.defaultDaemonCapabilitiesFetcher() },
            daemonClient: DaemonClientDouble(),
            profileBalancingFlagSetter: { _ in },
            limitRotationFlagSetter: { _ in },
            profilePoolOptOutSetter: { _, _ in setterCalled = true }
        )

        let profileID = UUID()
        await appState.setProfilePoolOptOut(id: profileID, optOut: true)

        #expect(setterCalled)
        #expect(profilesReloaded)
    }

    // MARK: - LimitBannerModel Tests

    @Test
    func limitBannerModelForSuggestedProfile() {
        let now = Date()
        let resetTime = now.addingTimeInterval(3600)
        let profileID = UUID()
        let suggestedID = UUID()

        let limitHit = TerminalLimitHit(
            profileID: profileID,
            resetsAt: resetTime,
            limitType: "session",
            suggestedProfileID: suggestedID,
            rotatedToProfileID: nil,
            receivedAt: now
        )

        let limitedProfile = ModelProfileWithUsage(
            profile: ModelProfile(id: profileID, name: "Limited", kind: .oauth)
        )

        let suggestedProfile = ModelProfileWithUsage(
            profile: ModelProfile(id: suggestedID, name: "Available", kind: .oauth),
            usageSnapshot: ProfileUsageSnapshot(
                organizationID: nil,
                statusKind: .ok,
                isOK: true,
                buckets: [
                    ClaudeUsageLimitBucket(kind: "session", percent: 30, resetsAt: resetTime, severity: nil, modelDisplayName: nil)
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
        #expect(model.isRotated == false)
    }

    @Test
    func limitBannerModelForRotatedSession() {
        let now = Date()
        let resetTime = now.addingTimeInterval(1800)

        let limitHit = TerminalLimitHit(
            profileID: UUID(),
            resetsAt: resetTime,
            limitType: "weekly_all",
            suggestedProfileID: nil,
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

        #expect(model.isRotated == true)
    }
}

/// Test double for DaemonClient
private class DaemonClientDouble: DaemonClient {
    init() {
        super.init(daemonURL: URL(fileURLWithPath: "/dev/null"))
    }

    override func setProfileBalancing(enabled: Bool) async throws {}
    override func setLimitRotation(enabled: Bool) async throws {}
    override func setProfilePoolOptOut(id: UUID, optOut: Bool) async throws {}
}
