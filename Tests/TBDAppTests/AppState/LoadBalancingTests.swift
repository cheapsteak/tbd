import Foundation
import Testing
import TBDShared
@testable import TBDApp

struct LoadBalancingTests {
    @Test
    func liveSessionCountPrefersDeamonValue() async {
        let appState = AppState(
            userDefaults: UserDefaults(suiteName: "test.load-balancing.daemon-live-count")!,
            modelProfilesFetcher: { try await AppState.defaultModelProfilesFetcher() },
            daemonCapabilitiesFetcher: { try await AppState.defaultDaemonCapabilitiesFetcher() },
            daemonClient: DaemonClientDouble(),
            profileBalancingFlagSetter: { _ in },
            limitRotationFlagSetter: { _ in },
            profilePoolOptOutSetter: { _, _ in }
        )

        let profileID = UUID()
        let entry = ModelProfileWithUsage(
            profile: ModelProfile(id: profileID, name: "Test", kind: .oauth),
            liveSessions: 5
        )
        appState.modelProfiles = [entry]

        let count = appState.liveSessionCount(forProfile: profileID)
        #expect(count == 5) // Prefers daemon value
    }

    @Test
    func liveSessionCountCountsTerminalsWhenDaemonHasNil() async {
        let appState = AppState(
            userDefaults: UserDefaults(suiteName: "test.load-balancing.local-count")!,
            modelProfilesFetcher: { try await AppState.defaultModelProfilesFetcher() },
            daemonCapabilitiesFetcher: { try await AppState.defaultDaemonCapabilitiesFetcher() },
            daemonClient: DaemonClientDouble(),
            profileBalancingFlagSetter: { _ in },
            limitRotationFlagSetter: { _ in },
            profilePoolOptOutSetter: { _, _ in }
        )

        let profileID = UUID()
        let worktreeID = UUID()
        let entry = ModelProfileWithUsage(
            profile: ModelProfile(id: profileID, name: "Test", kind: .oauth),
            liveSessions: nil
        )
        appState.modelProfiles = [entry]

        // Add some terminals
        let terminal1 = Terminal(
            id: UUID(),
            worktreeID: worktreeID,
            kind: .claude,
            profileID: profileID,
            hibernatedAt: nil,
            suspendedAt: nil
        )
        let terminal2 = Terminal(
            id: UUID(),
            worktreeID: worktreeID,
            kind: .claude,
            profileID: profileID,
            hibernatedAt: Date(), // Parked
            suspendedAt: nil
        )
        let terminal3 = Terminal(
            id: UUID(),
            worktreeID: worktreeID,
            kind: .claude,
            profileID: UUID(), // Different profile
            hibernatedAt: nil,
            suspendedAt: nil
        )
        appState.terminals[worktreeID] = [terminal1, terminal2, terminal3]

        let count = appState.liveSessionCount(forProfile: profileID)
        #expect(count == 1) // Only terminal1: unparked, Claude kind, matching profile
    }

    @Test
    func setProfileBalancingEnabledCallsSetter() async {
        var setterCalled = false
        let appState = AppState(
            userDefaults: UserDefaults(suiteName: "test.load-balancing.flag-setter")!,
            modelProfilesFetcher: { try await AppState.defaultModelProfilesFetcher() },
            daemonCapabilitiesFetcher: { try await AppState.defaultDaemonCapabilitiesFetcher() },
            daemonClient: DaemonClientDouble(),
            profileBalancingFlagSetter: { _ in setterCalled = true },
            limitRotationFlagSetter: { _ in },
            profilePoolOptOutSetter: { _, _ in }
        )

        await appState.setProfileBalancingEnabled(true)
        #expect(setterCalled)
    }

    @Test
    func limitHitsClearedOnActivityWorking() async {
        let appState = AppState(
            userDefaults: UserDefaults(suiteName: "test.load-balancing.limit-clear")!,
            modelProfilesFetcher: { try await AppState.defaultModelProfilesFetcher() },
            daemonCapabilitiesFetcher: { try await AppState.defaultDaemonCapabilitiesFetcher() },
            daemonClient: DaemonClientDouble(),
            profileBalancingFlagSetter: { _ in },
            limitRotationFlagSetter: { _ in },
            profilePoolOptOutSetter: { _, _ in }
        )

        let terminalID = UUID()
        let worktreeID = UUID()
        let profileID = UUID()

        // Set up a limit hit
        appState.limitHits[terminalID] = TerminalLimitHit(
            profileID: profileID,
            resetsAt: Date(),
            limitType: "session",
            suggestedProfileID: nil,
            rotatedToProfileID: nil,
            receivedAt: Date()
        )

        // Create a terminal
        appState.terminals[worktreeID] = [
            Terminal(
                id: terminalID,
                worktreeID: worktreeID,
                kind: .claude,
                profileID: profileID,
                activityState: .idle
            )
        ]

        // Apply activity delta with .working state
        appState.applyTerminalActivityDelta(
            TerminalActivityDelta(
                terminalID: terminalID,
                worktreeID: worktreeID,
                activityState: .working
            )
        )

        #expect(appState.limitHits[terminalID] == nil) // Should be cleared
    }

    @Test
    func limitHitsClearedOnProfileChange() async {
        let appState = AppState(
            userDefaults: UserDefaults(suiteName: "test.load-balancing.profile-change")!,
            modelProfilesFetcher: { try await AppState.defaultModelProfilesFetcher() },
            daemonCapabilitiesFetcher: { try await AppState.defaultDaemonCapabilitiesFetcher() },
            daemonClient: DaemonClientDouble(),
            profileBalancingFlagSetter: { _ in },
            limitRotationFlagSetter: { _ in },
            profilePoolOptOutSetter: { _, _ in }
        )

        let terminalID = UUID()
        let worktreeID = UUID()
        let oldProfileID = UUID()
        let newProfileID = UUID()

        // Set up a limit hit
        appState.limitHits[terminalID] = TerminalLimitHit(
            profileID: oldProfileID,
            resetsAt: Date(),
            limitType: "session",
            suggestedProfileID: nil,
            rotatedToProfileID: nil,
            receivedAt: Date()
        )

        // Create a terminal
        appState.terminals[worktreeID] = [
            Terminal(
                id: terminalID,
                worktreeID: worktreeID,
                kind: .claude,
                profileID: oldProfileID
            )
        ]

        // Apply profile change delta
        appState.applyTerminalProfileDelta(
            TerminalProfileDelta(
                terminalID: terminalID,
                worktreeID: worktreeID,
                newProfileID: newProfileID
            )
        )

        #expect(appState.limitHits[terminalID] == nil) // Should be cleared
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
