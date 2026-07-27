import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// One recorded `remoteAttachExitReporter` invocation.
struct ExitReport: Equatable {
    let provider: String
    let sessionID: String
    let exitCode: Int32
}

/// MainActor-isolated collector for the injected reporter seam — the
/// reporter closure is `@MainActor`, so no locking is needed.
@MainActor
final class ExitReportRecorder {
    var calls: [ExitReport] = []
}

/// Integration-through-`AppState` tests for the remote attach-lifecycle
/// wiring: `selectRemoteSession`/`activateRemoteSession` touching recency
/// and clearing (or not clearing) the explicit-detach flag,
/// `markRemoteSessionDetached`/`reattachRemoteSession` (including its
/// unexpected-exit → `pendingReconnectRemoteSessions` routing and
/// provider-health-driven auto-reattach), and pruning on mirror refresh.
/// Mirrors `KeepAliveEvictionTests`'s "integration through AppState computed
/// properties" section — the pure decisions themselves
/// (`RemoteAttachLifecycle.attachedSelections`, `RemoteReconnectPolicy`) are
/// covered exhaustively in `RemoteAttachLifecycleTests`/
/// `RemoteReconnectPolicyTests`; these tests only need to prove the plumbing
/// feeds them correctly.
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
    /// capability — the fixture used for capability-gating tests. Re-calling
    /// with the same `name` replaces the roster entry (used to simulate a
    /// health transition, e.g. `.stale` → `.ok`, across a poll refresh).
    private func seedProvider(_ state: AppState, name: String, attachCapable: Bool = true, health: ProviderHealth = .ok) {
        state.remoteProviders = state.remoteProviders.filter { $0.config.name != name } + [
            RemoteProviderStatus(
                config: RemoteProviderConfig(name: name, exec: "/usr/bin/true"),
                describe: ProviderDescribe(name: name, capabilities: attachCapable ? ["attach", "log"] : ["log"]),
                health: health, errorMessage: nil, remediationLabel: nil, remediationCommand: nil
            )
        ]
    }

    private func seedSession(_ state: AppState, provider: String, id: String, gone: Bool = false, dismissed: Bool = false) {
        state.remoteSessions.append(RemoteSessionInfo(
            provider: provider,
            payload: RemoteSessionPayload(id: id, state: .running),
            gone: gone, dismissed: dismissed, lastSeen: Date()
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

    /// `attachEligibleRemoteSelections` must exclude `dismissed` sessions the
    /// same way it excludes `gone` ones, so it can never disagree with the
    /// navigation-staleness predicate (`usableEntryIndex` in
    /// `AppState+Navigation.swift`), which excludes `dismissed` but keeps
    /// `gone` — see that computed property's doc comment.
    @Test func selectingADismissedSessionNeverAttaches() {
        withState { state in
            seedProvider(state, name: "acme")
            seedSession(state, provider: "acme", id: "s1", dismissed: true)

            state.selectRemoteSession(provider: "acme", sessionID: "s1")

            #expect(!state.attachedRemoteSelections.contains(sel("acme", "s1")))
            #expect(!state.attachEligibleRemoteSelections.contains(sel("acme", "s1")))
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
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 0)
            #expect(!state.attachedRemoteSelections.contains(sel("acme", "s1")))

            state.reattachRemoteSession(sel("acme", "s1"))

            #expect(state.attachedRemoteSelections.contains(sel("acme", "s1")))
            #expect(state.explicitlyDetachedRemoteSessions[sel("acme", "s1")] == nil)
        }
    }

    /// `reattachRemoteSession` is the unconditional override for BOTH detach
    /// mechanisms — it must clear a pending-reconnect entry too, and bypass
    /// its backoff window, even while the provider is still unhealthy.
    @Test func reattachRemoteSessionClearsAPendingReconnectEntryToo() {
        withState { state in
            seedProvider(state, name: "acme", health: .stale)
            seedSession(state, provider: "acme", id: "s1")
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 1)
            #expect(!state.attachedRemoteSelections.contains(sel("acme", "s1")))

            state.reattachRemoteSession(sel("acme", "s1"))

            #expect(state.attachedRemoteSelections.contains(sel("acme", "s1")))
            #expect(state.pendingReconnectRemoteSessions[sel("acme", "s1")] == nil)
        }
    }

    @Test func markRemoteSessionDetachedRecordsTheExitCodeForACleanDetach() {
        withState { state in
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 0)
            #expect(state.explicitlyDetachedRemoteSessions[sel("acme", "s1")]?.exitCode == 0)
        }
    }

    // MARK: - Unexpected exit → pending reconnect (not explicit detach)

    /// The core routing rule for this task: a NONZERO exit code goes to
    /// `pendingReconnectRemoteSessions`, never `explicitlyDetachedRemoteSessions`
    /// — an unexpected exit is the transport's fault, not a user detach.
    @Test func unexpectedExitRecordsAPendingReconnectEntryNotAnExplicitDetach() {
        withState { state in
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 137)
            #expect(state.pendingReconnectRemoteSessions[sel("acme", "s1")]?.exitCode == 137)
            #expect(state.explicitlyDetachedRemoteSessions[sel("acme", "s1")] == nil)
        }
    }

    /// A clean exit (0) always wins over stale pending-reconnect bookkeeping
    /// from an earlier flapping run for the same selection.
    @Test func cleanExitAfterAPendingReconnectClearsThePendingEntry() {
        withState { state in
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 1)
            #expect(state.pendingReconnectRemoteSessions[sel("acme", "s1")] != nil)

            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 0)

            #expect(state.pendingReconnectRemoteSessions[sel("acme", "s1")] == nil)
            #expect(state.explicitlyDetachedRemoteSessions[sel("acme", "s1")] != nil)
        }
    }

    /// A clean exit stays detached across a health recovery — the brief's
    /// first required direction. `explicitlyDetachedRemoteSessions` is never
    /// touched by health transitions, only by an explicit gesture.
    @Test func cleanExitStaysDetachedAcrossAHealthRecovery() {
        withState { state in
            seedProvider(state, name: "acme", health: .stale)
            seedSession(state, provider: "acme", id: "s1")
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 0)
            #expect(!state.attachedRemoteSelections.contains(sel("acme", "s1")))

            // Provider recovers.
            seedProvider(state, name: "acme", health: .ok)

            #expect(!state.attachedRemoteSelections.contains(sel("acme", "s1")))
        }
    }

    /// An unexpected exit reattaches automatically once the provider is
    /// healthy again and the entry's (short, first-attempt) backoff window
    /// has elapsed — no Reattach click required. The second required
    /// direction from the brief.
    @Test func unexpectedExitReattachesOnHealthRecovery() {
        withState { state in
            seedProvider(state, name: "acme", health: .stale)
            seedSession(state, provider: "acme", id: "s1")
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 1)
            #expect(!state.attachedRemoteSelections.contains(sel("acme", "s1")))

            seedProvider(state, name: "acme", health: .ok)

            // `attachedRemoteSelections(now:)` is the testable, time-injected
            // core of `attachedRemoteSelections` — evaluate it at (and past)
            // the entry's own `nextEligibleAt` rather than depending on real
            // wall-clock elapsed time (no wall-clock freshness windows in
            // tests).
            let pending = state.pendingReconnectRemoteSessions[sel("acme", "s1")]
            #expect(pending != nil)
            if let pending {
                #expect(state.attachedRemoteSelections(now: pending.nextEligibleAt).contains(sel("acme", "s1")))
            }
        }
    }

    /// Must NOT reattach while the provider is still unhealthy — the third
    /// required direction. Backoff elapsing is not enough on its own.
    @Test func unexpectedExitDoesNotReattachWhileProviderIsStillUnhealthy() {
        withState { state in
            seedProvider(state, name: "acme", health: .stale)
            seedSession(state, provider: "acme", id: "s1")
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 1)

            // Provider is STILL unhealthy (no recovery) — confirm the block
            // holds even far beyond the backoff window.
            let pending = state.pendingReconnectRemoteSessions[sel("acme", "s1")]
            #expect(pending != nil)
            if let pending {
                let farFuture = pending.nextEligibleAt.addingTimeInterval(10_000)
                #expect(!state.attachedRemoteSelections(now: farFuture).contains(sel("acme", "s1")))
            }
        }
    }

    /// Auto-reattach after a health recovery is still bounded by the
    /// keep-alive cap — the fourth required direction. A laptop waking from
    /// a long outage with many pending sessions doesn't burst past the cap.
    @Test func pendingReconnectAutoReattachIsBoundedByTheCap() {
        withState { state in
            seedProvider(state, name: "acme", health: .stale)
            for i in 0..<6 { seedSession(state, provider: "acme", id: "s\(i)") }
            for i in 0..<6 {
                state.selectRemoteSession(provider: "acme", sessionID: "s\(i)")
                state.markRemoteSessionDetached(sel("acme", "s\(i)"), exitCode: 1)
            }
            for i in 0..<6 {
                #expect(!state.attachedRemoteSelections.contains(sel("acme", "s\(i)")))
            }

            seedProvider(state, name: "acme", health: .ok)

            // Evaluate well past every entry's backoff window — even with
            // ALL SIX simultaneously eligible to resume, the ordinary
            // `RemoteAttachLifecycle` cap still applies: never more than
            // `remoteAttachKeepAliveLimit + 1` (the always-protected current
            // selection plus the capped recency budget).
            let farFuture = Date().addingTimeInterval(10_000)
            #expect(state.attachedRemoteSelections(now: farFuture).count <= state.remoteAttachKeepAliveLimit + 1)
        }
    }

    // MARK: - Auth-class exit (provider can't authenticate)

    /// An auth-class exit takes the pending-reconnect path (so it clears
    /// itself once the provider recovers) rather than the explicit-detach
    /// path (which would demand a user gesture the user can't usefully make
    /// while the provider is unauthenticated).
    @Test func authExitRecordsAPendingReconnectEntryNotAnExplicitDetach() {
        withState { state in
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 4)
            #expect(state.pendingReconnectRemoteSessions[sel("acme", "s1")]?.exitCode == 4)
            #expect(state.explicitlyDetachedRemoteSessions[sel("acme", "s1")] == nil)
        }
    }

    /// A FIRST auth exit starts at `attempts` 1, i.e. the short base
    /// backoff — which is the only value the normal flow ever reaches,
    /// since the health gate blocks every retry from here on.
    @Test func firstAuthExitStartsAtAttemptsOne() {
        withState { state in
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 4)
            #expect(state.pendingReconnectRemoteSessions[sel("acme", "s1")]?.attempts == 1)
        }
    }

    /// Repeated auth exits escalate exactly like unexpected ones. That only
    /// happens in the pathological case where a provider's `list`
    /// authenticates (health clears, the session is re-admitted) but its
    /// `attach` doesn't — an otherwise unbounded ~5s respawn loop, each
    /// round costing a daemon probe. Escalation is the bound. See
    /// `RemoteReconnectPolicy.nextPending`.
    @Test func repeatedAuthExitsEscalateAttemptsLikeUnexpectedOnes() {
        withState { state in
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 4)
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 4)
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 4)
            #expect(state.pendingReconnectRemoteSessions[sel("acme", "s1")]?.attempts == 3)
        }
    }

    // MARK: - Local auth-exit knowledge (independent of daemon health)

    /// The app's own half of the auth CTA's gate: it knows the attach exited
    /// in the auth class without waiting for the fire-and-forget report to
    /// come back as published provider health.
    @Test func authExitIsVisibleLocallyWithoutAnyProviderHealthChange() {
        withState { state in
            // Provider is still `.ok` — nothing has told the daemon yet.
            seedProvider(state, name: "acme", health: .ok)
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 4)

            #expect(state.remoteSessionHasLocalAuthExit(sel("acme", "s1")))
        }
    }

    /// The other classes must not light it: a transport failure and a clean
    /// detach are not authentication problems, and neither is a selection
    /// with no pending entry at all.
    @Test func nonAuthExitsAreNotLocalAuthExits() {
        withState { state in
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 137)
            state.markRemoteSessionDetached(sel("acme", "s2"), exitCode: 0)
            state.markRemoteSessionDetached(sel("acme", "s3"), exitCode: nil)

            #expect(!state.remoteSessionHasLocalAuthExit(sel("acme", "s1")))
            #expect(!state.remoteSessionHasLocalAuthExit(sel("acme", "s2")))
            #expect(!state.remoteSessionHasLocalAuthExit(sel("acme", "s3")))
            #expect(!state.remoteSessionHasLocalAuthExit(sel("acme", "never-attached")))
        }
    }

    /// Reattach clears the pending entry outright, so the local signal goes
    /// with it — the CTA must not outlive the state that justified it.
    @Test func reattachClearsTheLocalAuthExitSignal() {
        withState { state in
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 4)
            #expect(state.remoteSessionHasLocalAuthExit(sel("acme", "s1")))

            state.reattachRemoteSession(sel("acme", "s1"))

            #expect(!state.remoteSessionHasLocalAuthExit(sel("acme", "s1")))
        }
    }

    // MARK: - Provider health gates first-ever attach

    /// A NEVER-attached session under an already-`.needsAuth` provider must
    /// not spawn a doomed attach. `pendingReconnectBlockedSelections` can't
    /// cover this — it only inspects selections that already have a pending
    /// entry, i.e. ones that already burned one.
    @Test func needsAuthProviderExcludesANeverAttachedSession() {
        withState { state in
            seedProvider(state, name: "acme", health: .needsAuth)
            seedSession(state, provider: "acme", id: "s1")

            #expect(!state.attachEligibleRemoteSelections.contains(sel("acme", "s1")))

            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            #expect(!state.attachedRemoteSelections.contains(sel("acme", "s1")))
        }
    }

    /// The asymmetry, pinned: `.stale` is ordinary transport flake on the
    /// CONTROL path (`list`), which says nothing about whether `attach` can
    /// connect. Blocking on it would turn one bad poll into "you can't open
    /// your sessions".
    @Test func staleProviderStillAllowsANeverAttachedSession() {
        withState { state in
            seedProvider(state, name: "acme", health: .stale)
            seedSession(state, provider: "acme", id: "s1")

            #expect(state.attachEligibleRemoteSelections.contains(sel("acme", "s1")))

            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            #expect(state.attachedRemoteSelections.contains(sel("acme", "s1")))
        }
    }

    /// Same for `.error` — a `list` that fails permanently is a broken
    /// control path, not proof that `attach` fails.
    @Test func errorProviderStillAllowsANeverAttachedSession() {
        withState { state in
            seedProvider(state, name: "acme", health: .error)
            seedSession(state, provider: "acme", id: "s1")

            #expect(state.attachEligibleRemoteSelections.contains(sel("acme", "s1")))

            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            #expect(state.attachedRemoteSelections.contains(sel("acme", "s1")))
        }
    }

    /// Recovery re-admits it with no user gesture — the gate is health, and
    /// health is republished by the daemon's poll.
    @Test func recoveryFromNeedsAuthReAdmitsTheSession() {
        withState { state in
            seedProvider(state, name: "acme", health: .needsAuth)
            seedSession(state, provider: "acme", id: "s1")
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            #expect(!state.attachedRemoteSelections.contains(sel("acme", "s1")))

            seedProvider(state, name: "acme", health: .ok)

            #expect(state.attachEligibleRemoteSelections.contains(sel("acme", "s1")))
            #expect(state.attachedRemoteSelections.contains(sel("acme", "s1")))
        }
    }

    @Test func repeatedUnexpectedExitsDoEscalateAttempts() {
        withState { state in
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 1)
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 1)
            #expect(state.pendingReconnectRemoteSessions[sel("acme", "s1")]?.attempts == 2)
        }
    }

    /// `RemoteReconnectPolicy.isBlocked` already blocks on any health other
    /// than `.ok`, so `.needsAuth` gates auto-reattach with NO second
    /// mechanism — pinned here rather than adding one. The session is
    /// re-admitted once health returns to `.ok` and backoff has elapsed.
    @Test func needsAuthProviderBlocksAutoReattachUntilHealthReturns() {
        withState { state in
            seedProvider(state, name: "acme", health: .needsAuth)
            seedSession(state, provider: "acme", id: "s1")
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 4)

            let pending = state.pendingReconnectRemoteSessions[sel("acme", "s1")]
            #expect(pending != nil)
            guard let pending else { return }

            // Backoff long elapsed, but the provider still can't authenticate.
            let farFuture = pending.nextEligibleAt.addingTimeInterval(10_000)
            #expect(!state.attachedRemoteSelections(now: farFuture).contains(sel("acme", "s1")))

            // A human re-authenticates; the daemon's next poll republishes `.ok`.
            seedProvider(state, name: "acme", health: .ok)

            #expect(state.attachedRemoteSelections(now: pending.nextEligibleAt).contains(sel("acme", "s1")))
        }
    }

    /// The auth exit is additionally reported to the daemon so provider
    /// health picks it up without waiting for the next poll. Fire-and-forget
    /// through the injected reporter seam — tests must never reach the real
    /// daemon socket.
    @Test func authExitReportsTheExitCodeToTheDaemon() async {
        let suiteName = "TBDAppTests.RemoteAttachState.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(userDefaults: defaults)
        let recorder = ExitReportRecorder()
        state.remoteAttachExitReporter = { provider, sessionID, exitCode in
            recorder.calls.append(ExitReport(provider: provider, sessionID: sessionID, exitCode: exitCode))
        }

        state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 4)

        await waitUntil { recorder.calls.count == 1 }
        #expect(recorder.calls == [ExitReport(provider: "acme", sessionID: "s1", exitCode: 4)])
    }

    /// The other two classes never report: a clean detach is not a failure
    /// at all, and a transport failure is handled entirely app-side by
    /// reconnect backoff.
    @Test func cleanAndUnexpectedExitsDoNotReportToTheDaemon() async {
        let suiteName = "TBDAppTests.RemoteAttachState.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(userDefaults: defaults)
        let recorder = ExitReportRecorder()
        state.remoteAttachExitReporter = { provider, sessionID, exitCode in
            recorder.calls.append(ExitReport(provider: provider, sessionID: sessionID, exitCode: exitCode))
        }

        state.markRemoteSessionDetached(sel("acme", "s1"), exitCode: 0)
        state.markRemoteSessionDetached(sel("acme", "s2"), exitCode: 137)
        state.markRemoteSessionDetached(sel("acme", "s3"), exitCode: nil)

        // Give any (incorrectly) spawned report Task a chance to land before
        // asserting the negative. A mis-route would enqueue its Task
        // synchronously inside `markRemoteSessionDetached`, so one
        // scheduling turn is enough to catch it — this window is generous.
        await waitUntil({ !recorder.calls.isEmpty }, timeout: 0.5)
        #expect(recorder.calls.isEmpty)
    }

    /// Bounded wait for a MainActor-isolated condition — the reporter fires
    /// from a `Task`, so the assertion can't be made synchronously.
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Sticky host selection (survives navigating away)

    /// `remoteSessionHostSelection` is what `DetailSectionHostPager`'s
    /// `.remote` tab renders for while it's mounted-but-hidden (see that
    /// type's doc comment) — the whole point of the fix this task is about:
    /// a session that was selected, then left (e.g. the user clicked over
    /// to a worktree), must still resolve to something so the hidden host
    /// keeps describing the right session rather than going blank.
    @Test func hostSelectionIsNilBeforeAnySessionIsEverSelected() {
        withState { state in
            #expect(state.remoteSessionHostSelection == nil)
        }
    }

    @Test func hostSelectionIsTheActiveSelectionWhileOneIsSelected() {
        withState { state in
            seedProvider(state, name: "acme")
            seedSession(state, provider: "acme", id: "s1")
            state.selectRemoteSession(provider: "acme", sessionID: "s1")

            #expect(state.remoteSessionHostSelection == sel("acme", "s1"))
        }
    }

    /// The core "survives navigating away" case: once nothing is selected
    /// (mirrors a worktree/repo/scratch section becoming active, which sets
    /// `selectedRemoteSession = nil`), the host selection falls back to the
    /// most-recently-viewed remote session rather than going nil.
    @Test func hostSelectionFallsBackToMostRecentlyViewedOnceNothingIsSelected() {
        withState { state in
            seedProvider(state, name: "acme")
            seedSession(state, provider: "acme", id: "s1")
            seedSession(state, provider: "acme", id: "s2")
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.selectRemoteSession(provider: "acme", sessionID: "s2")

            // Simulate navigating to a worktree section (AppState+Worktrees.swift
            // clears `selectedRemoteSession` on that transition).
            state.selectedRemoteSession = nil

            #expect(state.remoteSessionHostSelection == sel("acme", "s2"))
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
