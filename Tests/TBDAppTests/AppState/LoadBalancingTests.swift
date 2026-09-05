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
                buckets: [
                        ClaudeUsageLimitBucket(kind: "session", percent: 20, severity: nil, resetsAt: Date(), modelDisplayName: nil)
                    ],
                fetchedAt: Date(),
                lastAttemptAt: Date(),
                status: "ok",
                statusKind: .ok,
                organizationID: nil
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

    /// Runs `body` against an `AppState` on an isolated `UserDefaults` suite
    /// and tears the suite down, so nothing reaches the developer's real
    /// TBDApp.plist (see CLAUDE.md, "Tests must not touch ~/tbd").
    @MainActor
    private func withAppState(_ tag: String, _ body: (AppState) async throws -> Void) async throws {
        let suiteName = "test.loadbalancing.\(tag).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await body(AppState(userDefaults: defaults))
    }

    private func claudeTerminal(worktreeID: UUID, profileID: UUID?, kind: TerminalKind = .claude,
                                hibernatedAt: Date? = nil, id: UUID = UUID()) -> Terminal {
        Terminal(id: id, worktreeID: worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
                 profileID: profileID, kind: kind, hibernatedAt: hibernatedAt)
    }

    @Test @MainActor
    func liveSessionCountPrefersDaemonValue() async throws {
        try await withAppState("daemon-count") { appState in
            let profileID = UUID()
            appState.modelProfiles = [
                ModelProfileWithUsage(profile: ModelProfile(id: profileID, name: "Test", kind: .oauth),
                                      liveSessions: 5)
            ]
            // A local terminal exists too; the daemon's figure still wins.
            let worktreeID = UUID()
            appState.terminals[worktreeID] = [claudeTerminal(worktreeID: worktreeID, profileID: profileID)]
            #expect(appState.liveSessionCount(forProfile: profileID) == 5)
        }
    }

    @Test @MainActor
    func liveSessionCountCountsOnlyUnparkedClaudeSessionsForTheProfile() async throws {
        try await withAppState("local-count") { appState in
            let profileID = UUID()
            let worktreeID = UUID()
            appState.modelProfiles = [
                ModelProfileWithUsage(profile: ModelProfile(id: profileID, name: "Test", kind: .oauth),
                                      liveSessions: nil)
            ]
            appState.terminals[worktreeID] = [
                claudeTerminal(worktreeID: worktreeID, profileID: profileID),                        // counts
                claudeTerminal(worktreeID: worktreeID, profileID: profileID, hibernatedAt: Date()),  // parked
                claudeTerminal(worktreeID: worktreeID, profileID: UUID()),                           // other profile
                claudeTerminal(worktreeID: worktreeID, profileID: profileID, kind: .shell),          // not Claude
            ]
            #expect(appState.liveSessionCount(forProfile: profileID) == 1)
        }
    }

    // MARK: - Limit Hits Lifecycle Tests

    @MainActor
    private func seedLimitHit(_ appState: AppState, terminalID: UUID) {
        appState.limitHits[terminalID] = TerminalLimitHit(
            profileID: UUID(), resetsAt: Date(), limitType: "session",
            suggestedProfileID: nil, rotatedToProfileID: nil, receivedAt: Date())
    }

    @Test @MainActor
    func limitHitsSetByDelta() async throws {
        try await withAppState("limit-set") { appState in
            let terminalID = UUID()
            let suggested = UUID()
            appState.handleDelta(.terminalLimitHit(TerminalLimitHitDelta(
                terminalID: terminalID, worktreeID: UUID(), profileID: UUID(),
                resetsAt: Date(), limitType: "session", suggestedProfileID: suggested)))
            #expect(appState.limitHits[terminalID]?.limitType == "session")
            #expect(appState.limitHits[terminalID]?.suggestedProfileID == suggested)
            #expect(appState.limitHits[terminalID]?.rotatedToProfileID == nil)
        }
    }

    @Test @MainActor
    func limitHitsClearedWhenTheSessionWorksAgain() async throws {
        try await withAppState("limit-clear-working") { appState in
            let terminalID = UUID()
            let worktreeID = UUID()
            appState.terminals[worktreeID] = [claudeTerminal(worktreeID: worktreeID, profileID: UUID(), id: terminalID)]
            seedLimitHit(appState, terminalID: terminalID)
            appState.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
                terminalID: terminalID, worktreeID: worktreeID, activityState: .idle)))
            #expect(appState.limitHits[terminalID] != nil, "idle is not recovery — the banner stays")
            appState.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
                terminalID: terminalID, worktreeID: worktreeID, activityState: .working)))
            #expect(appState.limitHits[terminalID] == nil)
        }
    }

    @Test @MainActor
    func limitHitsClearedOnProfileChange() async throws {
        try await withAppState("limit-clear-profile") { appState in
            let terminalID = UUID()
            let worktreeID = UUID()
            appState.terminals[worktreeID] = [claudeTerminal(worktreeID: worktreeID, profileID: UUID(), id: terminalID)]
            seedLimitHit(appState, terminalID: terminalID)
            appState.handleDelta(.terminalProfileChanged(TerminalProfileDelta(
                terminalID: terminalID, worktreeID: worktreeID, newProfileID: UUID())))
            #expect(appState.limitHits[terminalID] == nil)
        }
    }

    @Test @MainActor
    func limitHitsClearedOnRemoval() async throws {
        try await withAppState("limit-clear-removal") { appState in
            let terminalID = UUID()
            seedLimitHit(appState, terminalID: terminalID)
            appState.recordTerminalRemoval(terminalID: terminalID)
            #expect(appState.limitHits[terminalID] == nil)
        }
    }

    @Test @MainActor
    func limitHitsClearedOnDismiss() async throws {
        try await withAppState("limit-clear-dismiss") { appState in
            let terminalID = UUID()
            seedLimitHit(appState, terminalID: terminalID)
            appState.limitHits.removeValue(forKey: terminalID)   // what the banner's Dismiss does
            #expect(appState.limitHits[terminalID] == nil)
        }
    }

    // MARK: - Flag Setter Tests

    @Test @MainActor
    func profileBalancingSetterCallsClosureAndRefreshesCapabilities() async throws {
        try await withAppState("balancing-setter") { appState in
            let received = ValueBox<Bool>()
            let refreshed = ValueBox<Bool>()
            appState.profileBalancingFlagSetter = { enabled in received.value = enabled }
            appState.daemonCapabilitiesFetcher = { refreshed.value = true; return nil }
            await appState.setProfileBalancingEnabled(true)
            #expect(received.value == true)
            #expect(refreshed.value == true)
        }
    }

    @Test @MainActor
    func limitRotationSetterCallsClosureAndRefreshesCapabilities() async throws {
        try await withAppState("rotation-setter") { appState in
            let received = ValueBox<Bool>()
            let refreshed = ValueBox<Bool>()
            appState.limitRotationFlagSetter = { enabled in received.value = enabled }
            appState.daemonCapabilitiesFetcher = { refreshed.value = true; return nil }
            await appState.setLimitRotationEnabled(false)
            #expect(received.value == false)
            #expect(refreshed.value == true)
        }
    }

    @Test @MainActor
    func poolOptOutSetterCallsClosure() async throws {
        try await withAppState("opt-out-setter") { appState in
            let received = ValueBox<(UUID, Bool)>()
            appState.profilePoolOptOutSetter = { id, optOut in received.value = (id, optOut) }
            let profileID = UUID()
            await appState.setProfilePoolOptOut(id: profileID, optOut: true)
            #expect(received.value?.0 == profileID)
            #expect(received.value?.1 == true)
        }
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
                buckets: [
                    ClaudeUsageLimitBucket(kind: "session", percent: 30, severity: nil, resetsAt: resetTime, modelDisplayName: nil)
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


/// Main-actor-only holder for a value a `@MainActor` closure hands back to
/// the test that installed it.
@MainActor
private final class ValueBox<Value> {
    var value: Value?
}
