import Foundation
import Testing
import TestSupport
@testable import TBDApp
import TBDShared

/// `AppState.reconnectRemoteSession` — the manual restart for an attach pane
/// whose transport died without its child exiting — and the restart
/// generation it drives: the generation is part of each pane's mount identity
/// (`attachedRemoteMountKeys`, what `RemoteAttachPager` keys its tab items
/// on), and it is how a superseded child's late exit is kept from detaching
/// the replacement.
///
/// Every test constructs `AppState(userDefaults:)` against a unique throwaway
/// suite — `UserDefaults.standard` on this unbundled executable is the
/// developer's real `TBDApp.plist`.
@MainActor
@Suite("Remote attach reconnect")
struct RemoteAttachReconnectTests {
    private func withState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.RemoteAttachReconnect.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    private func seedProvider(_ state: AppState, name: String) {
        state.remoteProviders = state.remoteProviders.filter { $0.config.name != name } + [
            RemoteProviderStatus(
                config: RemoteProviderConfig(name: name, exec: "/usr/bin/true"),
                describe: ProviderDescribe(name: name, capabilities: ["attach", "log"]),
                health: .ok, errorMessage: nil, remediationLabel: nil, remediationCommand: nil
            )
        ]
    }

    private func seedSession(_ state: AppState, provider: String, id: String) {
        state.remoteSessions.append(RemoteSessionInfo(
            provider: provider,
            payload: RemoteSessionPayload(id: id, state: .running),
            gone: false, dismissed: false, lastSeen: Date()
        ))
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

    // MARK: - Generation drives mount identity

    @Test func mountKeyStartsAtGenerationZero() {
        withState { state in
            let s1 = attached(state)
            #expect(state.attachedRemoteMountKeys == [RemoteAttachMountKey(selection: s1, generation: 0)])
        }
    }

    /// The pager tears down and respawns a pane exactly when its key changes,
    /// so a reconnect must change the key while keeping the session mounted.
    @Test func reconnectChangesTheMountKeyAndKeepsTheSessionMounted() {
        withState { state in
            let s1 = attached(state)
            let before = state.attachedRemoteMountKeys

            #expect(state.reconnectRemoteSession(s1))

            let after = state.attachedRemoteMountKeys
            #expect(after == [RemoteAttachMountKey(selection: s1, generation: 1)])
            #expect(Set(after).isDisjoint(with: Set(before)), "the old pane's key must fall out of the mount set")
        }
    }

    @Test func reconnectOnlyBumpsTheNamedSession() {
        withState { state in
            seedProvider(state, name: "acme")
            seedSession(state, provider: "acme", id: "s1")
            seedSession(state, provider: "acme", id: "s2")
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.selectRemoteSession(provider: "acme", sessionID: "s2")

            state.reconnectRemoteSession(sel("acme", "s2"))

            #expect(state.remoteAttachGeneration(for: sel("acme", "s1")) == 0)
            #expect(state.remoteAttachGeneration(for: sel("acme", "s2")) == 1)
        }
    }

    // MARK: - A superseded child's exit is not a detach

    /// The discriminating case: the killed child's exit, arriving tagged with
    /// the generation it was mounted under, must neither detach the session
    /// nor put it into backoff.
    @Test func exitFromASupersededGenerationIsDropped() {
        withState { state in
            let s1 = attached(state)
            state.reconnectRemoteSession(s1)

            state.markRemoteSessionDetached(s1, exitCode: 255, generation: 0)
            state.markRemoteSessionDetached(s1, exitCode: 0, generation: 0)

            #expect(state.pendingReconnectRemoteSessions[s1] == nil)
            #expect(state.explicitlyDetachedRemoteSessions[s1] == nil)
            #expect(state.attachedRemoteSelections.contains(s1))
        }
    }

    /// The other branch: the live generation's own exit still detaches.
    @Test func exitFromTheCurrentGenerationStillDetaches() {
        withState { state in
            let s1 = attached(state)
            state.reconnectRemoteSession(s1)

            state.markRemoteSessionDetached(s1, exitCode: 255, generation: 1)

            #expect(state.pendingReconnectRemoteSessions[s1] != nil)
            #expect(!state.attachedRemoteSelections.contains(s1))
        }
    }

    // MARK: - Detached sessions: reconnect behaves like reattach

    @Test func reconnectOfACleanlyDetachedSessionReattaches() {
        withState { state in
            let s1 = attached(state)
            state.markRemoteSessionDetached(s1, exitCode: 0, generation: 0)
            #expect(!state.attachedRemoteSelections.contains(s1))

            #expect(state.reconnectRemoteSession(s1))

            #expect(state.explicitlyDetachedRemoteSessions[s1] == nil)
            #expect(state.attachedRemoteSelections.contains(s1))
        }
    }

    /// Bypasses the backoff window: an unexpected exit leaves the session
    /// blocked until provider health republishes past the window, and a
    /// reconnect is an explicit request to connect now.
    @Test func reconnectOfAPendingSessionClearsBackoffAndReattaches() {
        withState { state in
            let s1 = attached(state)
            state.markRemoteSessionDetached(s1, exitCode: 255, generation: 0)
            #expect(!state.attachedRemoteSelections.contains(s1))

            #expect(state.reconnectRemoteSession(s1))

            #expect(state.pendingReconnectRemoteSessions[s1] == nil)
            #expect(state.attachedRemoteSelections.contains(s1))
        }
    }

    // MARK: - Nothing to reconnect

    /// A session with no pane — never viewed here — must not gain a fresh
    /// provider connection from a reconnect request.
    @Test func reconnectOfAnUnviewedSessionChangesNothing() {
        withState { state in
            seedProvider(state, name: "acme")
            seedSession(state, provider: "acme", id: "s1")

            #expect(!state.reconnectRemoteSession(sel("acme", "s1")))

            #expect(state.attachedRemoteSelections.isEmpty)
            #expect(state.remoteAttachGeneration(for: sel("acme", "s1")) == 0)
        }
    }

    // MARK: - The CLI's push reaches the same entry point

    @Test func reconnectDeltaBumpsTheNamedSessionsGeneration() {
        withState { state in
            let s1 = attached(state)

            state.handleDelta(.remoteSessionReconnectRequested(
                RemoteSessionReconnectDelta(provider: "acme", sessionID: "s1")))

            #expect(state.remoteAttachGeneration(for: s1) == 1)
            #expect(state.attachedRemoteMountKeys == [RemoteAttachMountKey(selection: s1, generation: 1)])
        }
    }

    // MARK: - Pruning

    @Test func pruningDropsTheGenerationOfASessionNoLongerReported() {
        withState { state in
            let s1 = attached(state)
            state.reconnectRemoteSession(s1)

            state.pruneRemoteAttachState(toKnownSelections: [])

            #expect(state.remoteAttachGeneration(for: s1) == 0)
        }
    }
}
