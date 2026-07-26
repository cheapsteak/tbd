import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Integration-through-`AppState` tests for the remote attach-lifecycle
/// wiring: `selectRemoteSession`/`activateRemoteSession` touching recency
/// and clearing (or not clearing) the explicit-detach flag,
/// `markRemoteSessionDetached`/`reattachRemoteSession`, and pruning on
/// mirror refresh. Mirrors `KeepAliveEvictionTests`'s "integration through
/// AppState computed properties" section — the pure decision itself
/// (`RemoteAttachLifecycle.attachedSelections`) is covered exhaustively in
/// `RemoteAttachLifecycleTests`; these tests only need to prove the plumbing
/// feeds it correctly.
///
/// Every test constructs `AppState(userDefaults:)` against a unique throwaway
/// suite — TBDApp ships as an unbundled SPM executable, so `UserDefaults.standard`
/// is the running developer's real `TBDApp.plist`.
@MainActor
@Suite("Remote attach state")
struct RemoteAttachStateTests {
    private func withState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.RemoteAttachState.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    /// `attachCapable: false` builds a provider that declares no "attach"
    /// capability — the fixture used for capability-gating tests.
    private func seedProvider(_ state: AppState, name: String, attachCapable: Bool = true) {
        state.remoteProviders = [
            RemoteProviderStatus(
                config: RemoteProviderConfig(name: name, exec: "/usr/bin/true"),
                describe: ProviderDescribe(name: name, capabilities: attachCapable ? ["attach", "log"] : ["log"]),
                health: .ok, errorMessage: nil, remediationLabel: nil, remediationCommand: nil
            )
        ]
    }

    private func seedSession(_ state: AppState, provider: String, id: String, gone: Bool = false) {
        state.remoteSessions.append(RemoteSessionInfo(
            provider: provider,
            payload: RemoteSessionPayload(id: id, state: .running),
            gone: gone, dismissed: false, lastSeen: Date()
        ))
    }

    private func sel(_ provider: String, _ id: String) -> RemoteSessionSelection {
        RemoteSessionSelection(provider: provider, sessionID: id)
    }

    // MARK: - Selecting attaches (eligibility-gated)

    @Test func selectingAnAttachCapableSessionMakesItAttached() {
        withState { state in
            seedProvider(state, name: "acme")
            seedSession(state, provider: "acme", id: "s1")

            state.selectRemoteSession(provider: "acme", sessionID: "s1")

            #expect(state.attachedRemoteSelections.contains(sel("acme", "s1")))
        }
    }

    @Test func selectingALogOnlyProviderNeverAttaches() {
        withState { state in
            seedProvider(state, name: "acme", attachCapable: false)
            seedSession(state, provider: "acme", id: "s1")

            state.selectRemoteSession(provider: "acme", sessionID: "s1")

            #expect(!state.attachedRemoteSelections.contains(sel("acme", "s1")))
        }
    }

    @Test func selectingAGoneSessionNeverAttaches() {
        withState { state in
            seedProvider(state, name: "acme")
            seedSession(state, provider: "acme", id: "s1", gone: true)

            state.selectRemoteSession(provider: "acme", sessionID: "s1")

            #expect(!state.attachedRemoteSelections.contains(sel("acme", "s1")))
        }
    }

    @Test func selectingAnUnregisteredProviderSessionNeverAttaches() {
        withState { state in
            // No `remoteProviders` entry at all for "acme".
            seedSession(state, provider: "acme", id: "s1")

            state.selectRemoteSession(provider: "acme", sessionID: "s1")

            #expect(!state.attachedRemoteSelections.contains(sel("acme", "s1")))
        }
    }

    // MARK: - Cap-bounded keep-alive across selections

    @Test func recentlyViewedSessionsStayAttachedUpToTheCap() {
        withState { state in
            seedProvider(state, name: "acme")
            for i in 0..<10 { seedSession(state, provider: "acme", id: "s\(i)") }

            for i in 0..<10 { state.selectRemoteSession(provider: "acme", sessionID: "s\(i)") }

            // The cap plus the always-protected current selection.
            #expect(state.attachedRemoteSelections.count == state.remoteAttachKeepAliveLimit + 1)
            // Most-recently-viewed survive; the earliest do not.
            #expect(state.attachedRemoteSelections.contains(sel("acme", "s9")))
            #expect(!state.attachedRemoteSelections.contains(sel("acme", "s0")))
        }
    }

    // MARK: - Explicit-detach state rule

    @Test func detachedSessionIsExcludedWhileStillSelected() {
        withState { state in
            seedProvider(state, name: "acme")
            seedSession(state, provider: "acme", id: "s1")
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            #expect(state.attachedRemoteSelections.contains(sel("acme", "s1")))

            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 0)

            #expect(!state.attachedRemoteSelections.contains(sel("acme", "s1")))
        }
    }

    /// The core "no re-attach loop" rule: reselecting the SAME session that
    /// is already the current selection (no `.attach` tab request) must NOT
    /// clear a stale detach flag — otherwise the pty exiting while its row
    /// stays selected would silently respawn on the next redundant
    /// selection/render.
    @Test func redundantReselectionOfTheSameDetachedSessionDoesNotReattach() {
        withState { state in
            seedProvider(state, name: "acme")
            seedSession(state, provider: "acme", id: "s1")
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 0)

            // Redundant: same session, no explicit .attach tab request.
            state.selectRemoteSession(provider: "acme", sessionID: "s1")

            #expect(!state.attachedRemoteSelections.contains(sel("acme", "s1")))
        }
    }

    /// A genuine transition INTO a previously-detached session (coming from
    /// something else) DOES clear the stale flag — this is what makes
    /// "come back later" auto-attach again without an explicit Reattach
    /// click.
    @Test func transitioningIntoADetachedSessionFromElsewhereReattaches() {
        withState { state in
            seedProvider(state, name: "acme")
            seedSession(state, provider: "acme", id: "s1")
            seedSession(state, provider: "acme", id: "s2")
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 0)

            state.selectRemoteSession(provider: "acme", sessionID: "s2") // transition away
            state.selectRemoteSession(provider: "acme", sessionID: "s1") // transition back

            #expect(state.attachedRemoteSelections.contains(sel("acme", "s1")))
        }
    }

    /// The context menu's "Attach" item (`tab: .attach`) is an explicit
    /// re-attach request even when the row is ALREADY the current
    /// selection — this is the path that keeps "Keep the Attach
    /// context-menu item ... it's how you re-attach after detaching" true.
    @Test func explicitAttachTabRequestReattachesEvenWithoutATransition() {
        withState { state in
            seedProvider(state, name: "acme")
            seedSession(state, provider: "acme", id: "s1")
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 0)

            state.selectRemoteSession(provider: "acme", sessionID: "s1", tab: .attach)

            #expect(state.attachedRemoteSelections.contains(sel("acme", "s1")))
        }
    }

    @Test func reattachRemoteSessionClearsTheFlagAndReattaches() {
        withState { state in
            seedProvider(state, name: "acme")
            seedSession(state, provider: "acme", id: "s1")
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 1)
            #expect(!state.attachedRemoteSelections.contains(sel("acme", "s1")))

            state.reattachRemoteSession(sel("acme", "s1"))

            #expect(state.attachedRemoteSelections.contains(sel("acme", "s1")))
            #expect(state.explicitlyDetachedRemoteSessions[sel("acme", "s1")] == nil)
        }
    }

    @Test func markRemoteSessionDetachedRecordsTheExitCode() {
        withState { state in
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 137)
            #expect(state.explicitlyDetachedRemoteSessions[sel("acme", "s1")]?.exitCode == 137)
        }
    }

    // MARK: - Pruning on mirror refresh

    @Test func pruningDropsDetachAndRecencyStateForSessionsNoLongerReported() {
        withState { state in
            seedProvider(state, name: "acme")
            seedSession(state, provider: "acme", id: "s1")
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 0)

            // The daemon no longer reports s1 at all (dismissed elsewhere).
            state.pruneRemoteSessionState(toKnownSessions: [])

            #expect(state.explicitlyDetachedRemoteSessions[sel("acme", "s1")] == nil)
        }
    }

    @Test func pruningKeepsStateForStillReportedSessions() {
        withState { state in
            seedProvider(state, name: "acme")
            seedSession(state, provider: "acme", id: "s1")
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 0)

            state.pruneRemoteSessionState(toKnownSessions: state.remoteSessions)

            #expect(state.explicitlyDetachedRemoteSessions[sel("acme", "s1")] != nil)
        }
    }
}
