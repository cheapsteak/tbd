import Foundation
import Testing
import TestSupport
@testable import TBDApp
import TBDShared

// Tier 1: deterministic, in-process state only. No network, no clock.

/// `AppState.handleNetworkChange` (#884) — what a debounced network path
/// change or wake does to live attach panes and to sessions sitting in
/// reconnect backoff.
///
/// The helpers mirror `RemoteAttachReconnectTests`'s (copied rather than
/// shared, so that suite's part-1 assertions stay exactly as they were).
/// Every test constructs `AppState(userDefaults:)` against a unique throwaway
/// suite — `UserDefaults.standard` on this unbundled executable is the
/// developer's real `TBDApp.plist`.
@MainActor
@Suite("Remote attach network recovery")
struct RemoteAttachNetworkRecoveryTests {
    private func withState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.RemoteAttachNetworkRecovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    private func seedProvider(_ state: AppState, name: String, health: ProviderHealth = .ok) {
        state.remoteProviders = state.remoteProviders.filter { $0.config.name != name } + [
            RemoteProviderStatus(
                config: RemoteProviderConfig(name: name, exec: "/usr/bin/true"),
                describe: ProviderDescribe(name: name, capabilities: ["attach", "log"]),
                health: health, errorMessage: nil, remediationLabel: nil, remediationCommand: nil
            )
        ]
    }

    private func seedSession(_ state: AppState, provider: String, id: String, gone: Bool = false) {
        state.remoteSessions = state.remoteSessions.filter { !($0.provider == provider && $0.payload.id == id) } + [
            RemoteSessionInfo(
                provider: provider,
                payload: RemoteSessionPayload(id: id, state: .running),
                gone: gone, dismissed: false, lastSeen: Date()
            )
        ]
    }

    private func sel(_ provider: String, _ id: String) -> RemoteSessionSelection {
        RemoteSessionSelection(provider: provider, sessionID: id)
    }

    /// Seeds one attach-capable session and selects it, so it is mounted.
    private func attached(_ state: AppState) -> RemoteSessionSelection {
        seedProvider(state, name: "acme")
        seedSession(state, provider: "acme", id: "s1")
        state.selectRemoteSession(provider: "acme", sessionID: "s1")
        return sel("acme", "s1")
    }

    /// A change as the watcher would hand it over. Only `at` is load-bearing
    /// for the handler; the fingerprints reach the log line and nothing else.
    private func change(at date: Date) -> RemoteAttachNetworkChange {
        RemoteAttachNetworkChange(triggers: [.path], previous: nil, current: nil, at: date)
    }

    // MARK: - Restarting live children

    /// The whole point: a child that was already running when the path moved
    /// is the one that may be stranded on a dead socket. Reddens if the
    /// start-time comparison is dropped in the "restart everything" direction.
    @Test("a child that started before the change gets a new generation")
    func aChildStartedBeforeTheChangeIsRestarted() {
        withState { state in
            let s1 = attached(state)
            let t = Date()
            state.markRemoteAttachStarted(s1, generation: 0, at: t.addingTimeInterval(-1))

            state.handleNetworkChange(change(at: t))

            #expect(state.remoteAttachGeneration(for: s1) == 1)
        }
    }

    /// The other direction: a child spawned since the change is already on the
    /// new path, and restarting it would cost a repaint for nothing. Reddens
    /// if the comparison is dropped, or inverted.
    @Test("a child that started after the change keeps its generation")
    func aChildStartedAfterTheChangeIsLeftAlone() {
        withState { state in
            let s1 = attached(state)
            let t = Date()
            state.markRemoteAttachStarted(s1, generation: 0, at: t.addingTimeInterval(1))

            state.handleNetworkChange(change(at: t))

            #expect(state.remoteAttachGeneration(for: s1) == 0)
        }
    }

    /// No recorded start means the pane is mounted but its child has not
    /// spawned yet — it will spawn on the new path by itself. Reddens if a nil
    /// start is treated as "ancient" (the `<` comparison collapsing to a
    /// nil-coalesced `.distantPast`).
    @Test("a child with no recorded start keeps its generation")
    func aChildWithNoRecordedStartIsLeftAlone() {
        withState { state in
            let s1 = attached(state)
            #expect(state.remoteAttachStartedAt(for: s1) == nil)

            state.handleNetworkChange(change(at: Date()))

            #expect(state.remoteAttachGeneration(for: s1) == 0)
        }
    }

    // MARK: - Recording the spawn

    /// Reddens if `markRemoteAttachStarted` stops checking the generation: the
    /// killed child's report would date the replacement by the corpse, and the
    /// next network change would skip the pane that most needs restarting.
    @Test("a start reported for a superseded generation is dropped")
    func aSupersededStartReportIsDropped() {
        withState { state in
            let s1 = attached(state)
            state.reconnectRemoteSession(s1)

            state.markRemoteAttachStarted(s1, generation: 0, at: Date())

            #expect(state.remoteAttachStartedAt(for: s1) == nil)
            #expect(state.remoteAttachGeneration(for: s1) == 1)
        }
    }

    /// The live branch: the current generation's report is recorded verbatim.
    @Test("a start reported for the current generation is recorded")
    func aCurrentStartReportIsRecorded() {
        withState { state in
            let s1 = attached(state)
            state.reconnectRemoteSession(s1)
            let spawnedAt = Date()

            state.markRemoteAttachStarted(s1, generation: 1, at: spawnedAt)

            #expect(state.remoteAttachStartedAt(for: s1) == spawnedAt)
        }
    }

    /// Reddens if a generation bump carries the old child's start time
    /// forward: the fresh child would be dated before its own spawn, and a
    /// second change arriving during a burst would restart it needlessly.
    @Test("a reconnect clears the recorded start time")
    func aReconnectClearsTheRecordedStart() {
        withState { state in
            let s1 = attached(state)
            state.markRemoteAttachStarted(s1, generation: 0, at: Date())
            #expect(state.remoteAttachStartedAt(for: s1) != nil)

            state.reconnectRemoteSession(s1)

            #expect(state.remoteAttachStartedAt(for: s1) == nil)
            #expect(state.remoteAttachGeneration(for: s1) == 1)
        }
    }

    // MARK: - Expiring stale backoff

    /// A session that failed because the network was down would otherwise wait
    /// out its whole backoff after the network came back. Reddens if the
    /// backoff expiry is removed — the session stays excluded from
    /// `attachedRemoteSelections`.
    @Test("a pending session on a healthy provider becomes attachable at once")
    func pendingBackoffIsExpiredOnAHealthyProvider() {
        withState { state in
            let s1 = attached(state)
            let t = Date()
            state.markRemoteSessionDetached(s1, exitCode: 255, generation: 0)
            let before = state.pendingReconnectRemoteSessions[s1]
            #expect(before != nil)
            #expect(!state.attachedRemoteSelections.contains(s1), "still inside its backoff window")

            state.handleNetworkChange(change(at: t))

            let after = state.pendingReconnectRemoteSessions[s1]
            #expect(after?.nextEligibleAt == t)
            #expect(after?.attempts == before?.attempts, "escalation is the only bound on a respawn loop")
            #expect(after?.exitCode == before?.exitCode)
            #expect(state.attachedRemoteSelections.contains(s1))
        }
    }

    /// The health gate is untouched by design: the provider itself cannot
    /// authenticate, so a fresh `attach` would die on connect. Reddens if the
    /// handler clears entries outright instead of only moving their deadline.
    @Test("a pending session under a needsAuth provider stays blocked")
    func aNeedsAuthProviderStaysBlocked() {
        withState { state in
            let s1 = attached(state)
            state.markRemoteSessionDetached(s1, exitCode: 255, generation: 0)
            seedProvider(state, name: "acme", health: .needsAuth)

            state.handleNetworkChange(change(at: Date()))

            #expect(state.pendingReconnectRemoteSessions[s1] != nil)
            #expect(!state.attachEligibleRemoteSelections.contains(s1))
            #expect(!state.attachedRemoteSelections.contains(s1))
        }
    }

    /// Same gate, the other unhealthy state. `.error` does not block
    /// eligibility, so this one is blocked by `isBlocked`'s health check
    /// rather than by `attachEligibleRemoteSelections`.
    @Test("a pending session under an error provider stays blocked")
    func anErrorProviderStaysBlocked() {
        withState { state in
            let s1 = attached(state)
            state.markRemoteSessionDetached(s1, exitCode: 255, generation: 0)
            seedProvider(state, name: "acme", health: .error)

            state.handleNetworkChange(change(at: Date()))

            #expect(state.pendingReconnectRemoteSessions[s1] != nil)
            #expect(!state.attachedRemoteSelections.contains(s1))
        }
    }

    /// An entry whose window already elapsed is not stale, and moving its
    /// deadline FORWARD to the change time would delay a reattach the policy
    /// already admits. Reddens if the `> date` guard is dropped.
    @Test("a backoff that already elapsed is left untouched")
    func anElapsedBackoffIsLeftUntouched() {
        withState { state in
            let s1 = attached(state)
            let t = Date()
            let detachedAt = t.addingTimeInterval(-60)
            state.markRemoteSessionDetached(s1, exitCode: 255, generation: 0, now: detachedAt)
            let before = state.pendingReconnectRemoteSessions[s1]
            #expect(before?.nextEligibleAt == detachedAt.addingTimeInterval(RemoteReconnectPolicy.baseBackoff),
                    "the window closed well before the change")

            state.handleNetworkChange(change(at: t))

            #expect(state.pendingReconnectRemoteSessions[s1] == before)
        }
    }
}
