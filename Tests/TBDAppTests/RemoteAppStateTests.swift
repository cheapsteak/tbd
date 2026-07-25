import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Task 8 (remote agent backends — app state plumbing). Covers:
/// - `.remoteSessionsChanged` triggers the refresh path.
/// - `.remoteSessionAttention` posts a banner for both `kind` values, with
///   the title/id fallback and the reason in the body.
/// - `refreshRemote()` treats the daemon's "remote backends disabled"
///   refusal as "not available" (arrays cleared, no error logged) while a
///   genuine error is classified differently.
///
/// `DaemonClient` is a concrete actor (no protocol), so RPC-touching
/// coverage goes through the injectable `remoteProvidersFetcher` /
/// `remoteSessionsFetcher` seams (same pattern as `daemonCapabilitiesFetcher`
/// in `ModelProfileAppStateTests.swift`) rather than a live daemon.
@MainActor
@Suite("Remote backends — app state")
struct RemoteAppStateTests {

    private func withState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.Remote.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    // MARK: - refreshRemote()

    @Test func refreshRemote_populatesBothArraysOnSuccess() async {
        await withStateAsync { state in
            let provider = RemoteProviderStatus(
                config: RemoteProviderConfig(name: "acme", exec: "/bin/acme"),
                describe: nil, health: .ok, errorMessage: nil, remediationLabel: nil, remediationCommand: nil)
            let session = RemoteSessionInfo(
                provider: "acme",
                payload: RemoteSessionPayload(id: "s1", state: .running),
                gone: false, dismissed: false, lastSeen: Date())
            state.remoteProvidersFetcher = { RemoteProvidersResult(providers: [provider]) }
            state.remoteSessionsFetcher = { RemoteSessionsResult(sessions: [session]) }

            await state.refreshRemote()

            #expect(state.remoteProviders.count == 1)
            #expect(state.remoteSessions.count == 1)
        }
    }

    @Test func refreshRemote_disabledRefusal_clearsArraysWithoutError() async {
        await withStateAsync { state in
            // Seed stale data as if a previous successful fetch happened
            // while the flag was on, then the flag got flipped off.
            let provider = RemoteProviderStatus(
                config: RemoteProviderConfig(name: "acme", exec: "/bin/acme"),
                describe: nil, health: .ok, errorMessage: nil, remediationLabel: nil, remediationCommand: nil)
            state.remoteProviders = [provider]
            state.remoteSessions = [
                RemoteSessionInfo(provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                                   gone: false, dismissed: false, lastSeen: Date()),
            ]
            state.remoteProvidersFetcher = {
                throw DaemonClientError.rpcError(AppState.remoteBackendsDisabledMessage, code: nil)
            }
            state.remoteSessionsFetcher = {
                throw DaemonClientError.rpcError(AppState.remoteBackendsDisabledMessage, code: nil)
            }

            await state.refreshRemote()

            #expect(state.remoteProviders.isEmpty)
            #expect(state.remoteSessions.isEmpty)
        }
    }

    @Test func refreshRemote_genuineError_leavesLastKnownArraysInPlace() async {
        await withStateAsync { state in
            let provider = RemoteProviderStatus(
                config: RemoteProviderConfig(name: "acme", exec: "/bin/acme"),
                describe: nil, health: .ok, errorMessage: nil, remediationLabel: nil, remediationCommand: nil)
            state.remoteProviders = [provider]
            state.remoteProvidersFetcher = {
                throw DaemonClientError.connectionFailed("boom")
            }
            state.remoteSessionsFetcher = { RemoteSessionsResult(sessions: []) }

            await state.refreshRemote()

            // A genuine error must NOT be treated as "feature unavailable":
            // last-known state survives instead of being wiped.
            #expect(state.remoteProviders.count == 1)
        }
    }

    // MARK: - pruneRemoteSessionState (unread map / display names / dangling selection)

    /// `unreadByRemoteSession` and `remoteSessionDisplayNames` must be
    /// pruned to whatever the daemon just authoritatively returned — a
    /// dismissed-then-gone session is filtered out of the row list
    /// (`RemoteSectionView.sessions`) but never deleted from either map on
    /// its own, so without this the maps (the latter persisted to
    /// `UserDefaults`) grow forever.
    @Test func refreshRemote_prunesUnreadAndDisplayNamesForSessionsNoLongerReported() async {
        await withStateAsync { state in
            let survivor = RemoteSessionSelection(provider: "acme", sessionID: "s1")
            let gone = RemoteSessionSelection(provider: "acme", sessionID: "s2")
            state.unreadByRemoteSession[survivor] = UnreadSummary(type: .attentionNeeded, mostRecentAt: Date())
            state.unreadByRemoteSession[gone] = UnreadSummary(type: .error, mostRecentAt: Date())
            state.renameRemoteSession(provider: "acme", sessionID: "s1", displayName: "keep me")
            state.renameRemoteSession(provider: "acme", sessionID: "s2", displayName: "dead override")

            state.remoteProvidersFetcher = { RemoteProvidersResult(providers: []) }
            state.remoteSessionsFetcher = {
                RemoteSessionsResult(sessions: [
                    RemoteSessionInfo(provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                                       gone: false, dismissed: false, lastSeen: Date()),
                ])
            }

            await state.refreshRemote()

            #expect(state.unreadByRemoteSession[survivor] != nil)
            #expect(state.unreadByRemoteSession[gone] == nil)
            #expect(state.remoteSessionDisplayName(provider: "acme", sessionID: "s1", providerTitle: nil) == "keep me")
            let deadKey = AppState.remoteSessionKey(provider: "acme", sessionID: "s2")
            #expect(state.remoteSessionDisplayNames[deadKey] == nil)
        }
    }

    /// The disabled ("feature unavailable") path clears `remoteProviders`/
    /// `remoteSessions` locally without the daemon having reported anything
    /// — pruning against an empty list there would delete every rename
    /// override and unread entry the instant the flag flickers off, even
    /// transiently.
    @Test func refreshRemote_disabledRefusal_doesNotPruneDisplayNamesOrUnread() async {
        await withStateAsync { state in
            let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")
            state.unreadByRemoteSession[selection] = UnreadSummary(type: .attentionNeeded, mostRecentAt: Date())
            state.renameRemoteSession(provider: "acme", sessionID: "s1", displayName: "keep me")

            state.remoteProvidersFetcher = {
                throw DaemonClientError.rpcError(AppState.remoteBackendsDisabledMessage, code: nil)
            }
            state.remoteSessionsFetcher = {
                throw DaemonClientError.rpcError(AppState.remoteBackendsDisabledMessage, code: nil)
            }

            await state.refreshRemote()

            #expect(state.unreadByRemoteSession[selection] != nil,
                     "the disabled path must not prune unreadByRemoteSession")
            #expect(state.remoteSessionDisplayName(provider: "acme", sessionID: "s1", providerTitle: nil) == "keep me",
                     "the disabled path must not prune remoteSessionDisplayNames")
        }
    }

    /// `selectedRemoteSession` must not dangle once the session it points at
    /// is no longer in the daemon's authoritative list (dismissed or pruned).
    @Test func refreshRemote_clearsSelectedRemoteSessionWhenNoLongerReported() async {
        await withStateAsync { state in
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.remoteProvidersFetcher = { RemoteProvidersResult(providers: []) }
            state.remoteSessionsFetcher = { RemoteSessionsResult(sessions: []) }

            await state.refreshRemote()

            #expect(state.selectedRemoteSession == nil)
        }
    }

    /// Negative control: a still-reported selection must survive the refresh.
    @Test func refreshRemote_keepsSelectedRemoteSessionWhenStillReported() async {
        await withStateAsync { state in
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.remoteProvidersFetcher = { RemoteProvidersResult(providers: []) }
            state.remoteSessionsFetcher = {
                RemoteSessionsResult(sessions: [
                    RemoteSessionInfo(provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                                       gone: false, dismissed: false, lastSeen: Date()),
                ])
            }

            await state.refreshRemote()

            #expect(state.selectedRemoteSession == RemoteSessionSelection(provider: "acme", sessionID: "s1"))
        }
    }

    @Test func classifyRemoteRefreshFailure_disabledMessage_isUnavailable() {
        let error = DaemonClientError.rpcError(AppState.remoteBackendsDisabledMessage, code: nil)
        #expect(AppState.classifyRemoteRefreshFailure(error) == .unavailable)
    }

    @Test func classifyRemoteRefreshFailure_otherRPCError_isError() {
        let error = DaemonClientError.rpcError("something else went wrong", code: nil)
        #expect(AppState.classifyRemoteRefreshFailure(error) == .error)
    }

    @Test func classifyRemoteRefreshFailure_nonRPCError_isError() {
        let error = DaemonClientError.daemonNotRunning
        #expect(AppState.classifyRemoteRefreshFailure(error) == .error)
    }

    // MARK: - .remoteSessionsChanged triggers refreshRemote()

    @Test func remoteSessionsChangedDelta_triggersRefresh() async {
        await withStateAsync { state in
            let provider = RemoteProviderStatus(
                config: RemoteProviderConfig(name: "acme", exec: "/bin/acme"),
                describe: nil, health: .ok, errorMessage: nil, remediationLabel: nil, remediationCommand: nil)
            state.remoteProvidersFetcher = { RemoteProvidersResult(providers: [provider]) }
            state.remoteSessionsFetcher = { RemoteSessionsResult(sessions: []) }
            #expect(state.remoteProviders.isEmpty)

            state.handleDelta(.remoteSessionsChanged)

            // The handler spawns a Task — poll (CI-safe bound), mirrors
            // `appState_profilesChangedDeltaRefreshesDaemonCapabilities`.
            var refreshed = false
            for _ in 0..<1200 {
                if !state.remoteProviders.isEmpty { refreshed = true; break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            #expect(refreshed, ".remoteSessionsChanged must trigger refreshRemote()")
        }
    }

    // MARK: - .remoteSessionAttention banner text (pure seam)

    @Test func remoteAttentionTitle_waitingInput_usesTitleWhenPresent() {
        let delta = RemoteSessionAttentionDelta(
            provider: "acme", sessionID: "s1", title: "Fix the login bug",
            kind: "waiting_input", reason: "needs approval")
        #expect(AppState.remoteAttentionTitle(delta) == "Fix the login bug — needs input")
    }

    @Test func remoteAttentionTitle_exited_fallsBackToSessionID() {
        let delta = RemoteSessionAttentionDelta(
            provider: "acme", sessionID: "s1", title: nil,
            kind: "exited", reason: nil)
        #expect(AppState.remoteAttentionTitle(delta) == "s1 — finished")
    }

    @Test func remoteAttentionBody_usesReasonWhenPresent() {
        let delta = RemoteSessionAttentionDelta(
            provider: "acme", sessionID: "s1", title: nil,
            kind: "waiting_input", reason: "needs approval")
        #expect(AppState.remoteAttentionBody(delta) == "needs approval")
    }

    @Test func remoteAttentionBody_fallsBackToProviderWhenReasonNil() {
        let delta = RemoteSessionAttentionDelta(
            provider: "acme", sessionID: "s1", title: nil,
            kind: "exited", reason: nil)
        #expect(AppState.remoteAttentionBody(delta) == "acme")
    }

    // MARK: - .remoteSessionAttention does not touch worktree routing

    @Test func remoteSessionAttentionDelta_doesNotMutateWorktreeRouting() {
        withState { state in
            let delta = RemoteSessionAttentionDelta(
                provider: "acme", sessionID: "s1", title: "Fix the login bug",
                kind: "waiting_input", reason: "needs approval")

            // No worktree exists anywhere in state; this must not crash or
            // mutate worktree-routing state (selection, tabs, unread).
            state.handleDelta(.remoteSessionAttention(delta))

            #expect(state.selectedWorktreeIDs.isEmpty)
            #expect(state.unreadTerminals.isEmpty)
        }
    }

    // Helper: run an async body against a freshly-isolated AppState with
    // proper UserDefaults suite teardown (async variant of `withState`).
    private func withStateAsync(_ body: (AppState) async -> Void) async {
        let suiteName = "TBDAppTests.Remote.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        await body(AppState(userDefaults: defaults))
    }
}
