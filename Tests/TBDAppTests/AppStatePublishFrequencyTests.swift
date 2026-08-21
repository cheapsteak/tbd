import Foundation
import Testing
@testable import TBDApp
import TBDShared

// Tier 1: deterministic, in-process state only. No sleeps, no subprocesses, no
// `~/tbd`. Every `AppState` is built through `withEmissionState`, against a
// throwaway `UserDefaults` suite.
//
// WHAT THIS FILE MEASURES, AND WHY IT IS SHAPED THIS WAY
//
// `AppState` is an `ObservableObject` with ~107 `@Published` properties, read by
// ~56 view files through `@EnvironmentObject`. `objectWillChange` is object-wide,
// so one write to one property re-runs the body of every observing view. A
// property nobody reads costs exactly as much as one everybody reads; only how
// often it is *written* matters.
//
// The second mechanic is the one these tests are built around: `@Published`
// publishes on ASSIGNMENT, not on change. `willSet` sends `objectWillChange`
// before `didSet` runs, so an equality guard inside `didSet` suppresses the
// downstream work and none of the SwiftUI invalidation. Only a guard at the
// *assignment site* — or not being `@Published` at all — spares a render pass.
//
// So each significant writer is measured twice: once re-applying what is already
// there (the ideal is 0 emissions) and once applying a genuine change (the ideal
// is 1, and it is asserted for real, so a future "fix" that suppresses honest
// updates fails here).
//
// THE RATCHET. Where a path over-publishes today, the ideal is written as the
// assertion and wrapped in `withKnownIssue`. CI stays green now, and the moment
// someone fixes the path the test fails with "known issue was not recorded" —
// forcing the marker to be deleted and the ideal to become a live assertion.
// The file therefore encodes the intended end state, not the current one.
// Every marker names the property, the ideal, the count observed at the time of
// writing, and the shape of the fix.
//
// Tracked in issue #667.

// MARK: - Fixtures

@MainActor
private func makeWorktree(
    id: UUID = UUID(),
    repoID: UUID?,
    sortOrder: Int = 0
) -> Worktree {
    Worktree(
        id: id,
        repoID: repoID,
        name: "test-\(id.uuidString.prefix(8))",
        displayName: "Test \(id.uuidString.prefix(8))",
        branch: "main",
        path: "/tmp/test",
        status: .active,
        tmuxServer: "test-server",
        sortOrder: sortOrder
    )
}

private func makeTerminal(
    id: UUID = UUID(),
    worktreeID: UUID,
    activityState: TerminalActivityState = .idle,
    claudeSessionID: String? = "session-1",
    profileID: UUID? = nil
) -> Terminal {
    Terminal(
        id: id,
        worktreeID: worktreeID,
        tmuxWindowID: "@1",
        tmuxPaneID: "%1",
        label: "Claude",
        createdAt: Date(timeIntervalSince1970: 0),
        claudeSessionID: claudeSessionID,
        profileID: profileID,
        transcriptPath: "/tmp/transcript.jsonl",
        activityState: activityState
    )
}

/// Seat one worktree with one terminal through the production ingest path
/// (`adoptTerminalSnapshot`), so `terminals`, `tabs` and `activeTabIndices` all
/// reach the state a real poll would have left them in. Building those three by
/// hand would measure a fixture rather than the app.
@MainActor
private func seatOneTerminal(
    _ state: AppState,
    worktreeID: UUID,
    terminal: Terminal
) {
    let repoID = UUID()
    state.worktrees = [repoID: [makeWorktree(id: worktreeID, repoID: repoID)]]
    state.adoptTerminalSnapshot([terminal], worktreeID: worktreeID)
}

// MARK: - The mechanic itself

/// Direct re-assignment of an unchanged value. These are not exotic: they are
/// what a resize tick, a heartbeat, or a poll that found nothing new does when
/// its call site has no equality guard. The ideal for every one of them is 0.
@MainActor
@Suite("A @Published re-assignment publishes even when nothing changed")
struct IdempotentReassignmentTests {

    /// `mainAreaSize` is the known instance of the bug shape. Its `didSet`
    /// guards (`guard mainAreaSize != oldValue else { return }`,
    /// `AppState.swift:671`) — but that guard only suppresses the daemon
    /// broadcast, because `objectWillChange` was already sent by `willSet`. The
    /// single writer is `TerminalContainerView.swift:68`, inside
    /// `.onPreferenceChange(MainAreaSizeKey.self)`, which AppKit fires on every
    /// layout pass of a window-resize drag.
    @Test("mainAreaSize: re-assigning the current size")
    func mainAreaSize() {
        withEmissionState { state in
            let size = CGSize(width: 900, height: 600)
            state.mainAreaSize = size

            let count = countEmissions(of: state) { state.mainAreaSize = size }

            // KNOWN ISSUE — `AppState.mainAreaSize`. Ideal 0, observed 1.
            // The `didSet` guard cannot help; the fix is an equality guard at
            // the assignment site in `TerminalContainerView.onPreferenceChange`
            // (or dropping `@Published` and republishing manually).
            withKnownIssue("mainAreaSize republishes on every resize tick (#667)") {
                #expect(count == 0)
            }
        }
    }

    /// `isConnected` is written by the daemon-connection liveness path, which
    /// re-asserts the same `true` for as long as the connection holds.
    @Test("isConnected: re-assigning the current flag")
    func isConnected() {
        withEmissionState { state in
            state.isConnected = true

            let count = countEmissions(of: state) { state.isConnected = true }

            // KNOWN ISSUE — `AppState.isConnected`. Ideal 0, observed 1.
            // Fix: guard at the assignment site.
            withKnownIssue("isConnected republishes on an unchanged liveness result (#667)") {
                #expect(count == 0)
            }
        }
    }

    /// A dictionary property, to show the mechanic is not about value types:
    /// `Dictionary` is `Equatable` here and the values are identical, and the
    /// emission happens anyway.
    @Test("tabs: re-assigning an identical dictionary")
    func tabs() {
        withEmissionState { state in
            let worktreeID = UUID()
            let terminalID = UUID()
            let tab = TBDShared.Tab(
                id: terminalID,
                content: .terminal(terminalID: terminalID),
                label: "Claude"
            )
            state.tabs[worktreeID] = [tab]
            let snapshot = state.tabs

            let count = countEmissions(of: state) { state.tabs = snapshot }

            // KNOWN ISSUE — `AppState.tabs`. Ideal 0, observed 1.
            // Fix: guard at the assignment site (`reconcileTabs`, below).
            withKnownIssue("tabs republishes on an identical dictionary (#667)") {
                #expect(count == 0)
            }
        }
    }
}

/// The other half of the ratchet. A genuine change must keep publishing exactly
/// once — these are live assertions, so a "fix" that over-suppresses reds here.
@MainActor
@Suite("A genuine change publishes exactly once")
struct RealChangeTests {

    @Test("mainAreaSize: a new size")
    func mainAreaSize() {
        withEmissionState { state in
            state.mainAreaSize = CGSize(width: 900, height: 600)

            let count = countEmissions(of: state) {
                state.mainAreaSize = CGSize(width: 901, height: 600)
            }

            #expect(count == 1)
        }
    }

    @Test("isConnected: a flipped flag")
    func isConnected() {
        withEmissionState { state in
            state.isConnected = true

            let count = countEmissions(of: state) { state.isConnected = false }

            #expect(count == 1)
        }
    }

    @Test("tabs: a changed dictionary")
    func tabs() {
        withEmissionState { state in
            let worktreeID = UUID()
            let terminalID = UUID()
            state.tabs[worktreeID] = [
                TBDShared.Tab(id: terminalID, content: .terminal(terminalID: terminalID), label: "Claude")
            ]

            let count = countEmissions(of: state) {
                state.tabs[worktreeID] = []
            }

            #expect(count == 1)
        }
    }
}

// MARK: - Daemon delta ingestion

/// `handleDelta(_:)` (`AppState.swift:1991`) is the app's central daemon-push
/// handler — the highest-frequency non-gesture writer in the app, and
/// synchronous, so it can be driven exactly as the subscription drives it.
@MainActor
@Suite("Daemon delta ingestion")
struct DeltaIngestionTests {

    /// The single hottest delta in the app: the daemon stamps an agent's
    /// activity as it transitions, and re-sends on re-observation. The apply
    /// (`AppState.swift:2199`) writes through the subscript unconditionally.
    @Test("terminalActivityUpdated: the same activity state")
    func identicalActivityDelta() {
        withEmissionState { state in
            let worktreeID = UUID()
            let terminalID = UUID()
            seatOneTerminal(
                state,
                worktreeID: worktreeID,
                terminal: makeTerminal(id: terminalID, worktreeID: worktreeID, activityState: .working)
            )

            let count = countEmissions(of: state) {
                state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
                    terminalID: terminalID, worktreeID: worktreeID, activityState: .working
                )))
            }

            // KNOWN ISSUE — `AppState.terminals`, via
            // `applyTerminalActivityDelta` (AppState.swift:2199). Ideal 0,
            // observed 1. Fix: an equality guard at the assignment site —
            // `guard terminals[wt]?[idx].activityState != delta.activityState`.
            withKnownIssue("an unchanged activity state still republishes `terminals` (#667)") {
                #expect(count == 0)
            }
        }
    }

    @Test("terminalActivityUpdated: a new activity state")
    func changedActivityDelta() {
        withEmissionState { state in
            let worktreeID = UUID()
            let terminalID = UUID()
            seatOneTerminal(
                state,
                worktreeID: worktreeID,
                terminal: makeTerminal(id: terminalID, worktreeID: worktreeID, activityState: .idle)
            )

            let count = countEmissions(of: state) {
                state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
                    terminalID: terminalID, worktreeID: worktreeID, activityState: .working
                )))
            }

            #expect(count == 1)
            #expect(state.terminals[worktreeID]?.first?.activityState == .working)
        }
    }

    /// A session rollover delta re-sent with the same session identity is a
    /// semantic no-op and must not republish the terminal collection.
    @Test("terminalSessionUpdated: the same session and transcript path")
    func identicalSessionDelta() {
        withEmissionState { state in
            let worktreeID = UUID()
            let terminalID = UUID()
            seatOneTerminal(
                state,
                worktreeID: worktreeID,
                terminal: makeTerminal(id: terminalID, worktreeID: worktreeID, claudeSessionID: "abc")
            )

            let count = countEmissions(of: state) {
                state.handleDelta(.terminalSessionUpdated(TerminalSessionDelta(
                    terminalID: terminalID,
                    worktreeID: worktreeID,
                    sessionID: "abc",
                    transcriptPath: "/tmp/transcript.jsonl"
                )))
            }

            #expect(count == 0)
        }
    }

    @Test("terminalSessionUpdated: a new session id")
    func changedSessionDelta() {
        withEmissionState { state in
            let worktreeID = UUID()
            let terminalID = UUID()
            seatOneTerminal(
                state,
                worktreeID: worktreeID,
                terminal: makeTerminal(id: terminalID, worktreeID: worktreeID, claudeSessionID: "abc")
            )

            let count = countEmissions(of: state) {
                state.handleDelta(.terminalSessionUpdated(TerminalSessionDelta(
                    terminalID: terminalID,
                    worktreeID: worktreeID,
                    sessionID: "def",
                    transcriptPath: "/tmp/other.jsonl"
                )))
            }

            #expect(state.terminals[worktreeID]?.first?.claudeSessionID == "def")
            #expect(count == 1)
        }
    }

    @Test("terminalProfileChanged: the same profile")
    func identicalProfileDelta() {
        withEmissionState { state in
            let worktreeID = UUID()
            let terminalID = UUID()
            let profileID = UUID()
            seatOneTerminal(
                state,
                worktreeID: worktreeID,
                terminal: makeTerminal(id: terminalID, worktreeID: worktreeID, profileID: profileID)
            )

            let count = countEmissions(of: state) {
                state.handleDelta(.terminalProfileChanged(TerminalProfileDelta(
                    terminalID: terminalID, worktreeID: worktreeID, newProfileID: profileID
                )))
            }

            // KNOWN ISSUE — `AppState.terminals`, via
            // `applyTerminalProfileDelta` (AppState.swift:2204). Ideal 0,
            // observed 1. Fix: guard at the assignment site.
            withKnownIssue("an unchanged profile still republishes `terminals` (#667)") {
                #expect(count == 0)
            }
        }
    }

    /// One user-visible event — a session parks — applied as a run of separate
    /// subscript writes (`AppState.swift:2233`–`:2251`). Every one of them is a
    /// full object-wide invalidation, so the cost of a park scales with the
    /// number of fields the delta carries rather than with the one row it
    /// changes.
    @Test("terminalHibernationChanged: one park")
    func hibernationDeltaCost() {
        withEmissionState { state in
            let worktreeID = UUID()
            let terminalID = UUID()
            seatOneTerminal(
                state,
                worktreeID: worktreeID,
                terminal: makeTerminal(id: terminalID, worktreeID: worktreeID)
            )

            let count = countEmissions(of: state) {
                state.handleDelta(.terminalHibernationChanged(TerminalHibernationDelta(
                    terminalID: terminalID,
                    worktreeID: worktreeID,
                    hibernated: true,
                    keepWarm: false,
                    tmuxWindowID: "@2",
                    tmuxPaneID: "%2",
                    suspendedSnapshot: "snapshot",
                    hibernateReason: .manual
                )))
            }

            #expect(state.terminals[worktreeID]?.first?.hibernatedAt != nil)
            // KNOWN ISSUE — `AppState.terminals`, via
            // `applyTerminalHibernationDelta` (AppState.swift:2224). Ideal 1
            // (one logical park), observed 7 — one per field written through
            // the subscript. Fix: mutate a local copy of the row and assign it
            // back once.
            withKnownIssue("one park costs one publish per field written (#667)") {
                #expect(count == 1)
            }
        }
    }

    /// Control-mode input health is edge-triggered by the daemon, but the app
    /// must not assume that: a duplicate recovery must cost nothing.
    @Test("controlModeInputHealthChanged: healthy for an already-healthy pane")
    func redundantHealthyDelta() {
        withEmissionState { state in
            let worktreeID = UUID()
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%1", generation: 1)

            let count = countEmissions(of: state) {
                state.handleDelta(.controlModeInputHealthChanged(ControlModeInputHealthDelta(
                    worktreeID: worktreeID, paneID: "%1", healthy: true, generation: 1
                )))
            }

            // KNOWN ISSUE — `AppState.controlModeFailingInputPanes`, via
            // `applyControlModeInputHealthDelta` (AppState.swift:2101).
            // `Set.remove` on an absent member is still a get-modify-set of the
            // `@Published` property, so it publishes. Ideal 0, observed 1.
            // Fix: `guard controlModeFailingInputPanes.contains(key)`.
            withKnownIssue("a redundant recovery still republishes (#667)") {
                #expect(count == 0)
            }
        }
    }

    @Test("controlModeInputHealthChanged: a real failure")
    func failingHealthDelta() {
        withEmissionState { state in
            let worktreeID = UUID()
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%1", generation: 1)

            let count = countEmissions(of: state) {
                state.handleDelta(.controlModeInputHealthChanged(ControlModeInputHealthDelta(
                    worktreeID: worktreeID, paneID: "%1", healthy: false, generation: 1
                )))
            }

            #expect(state.isInputDeliveryFailing(
                ControlModePaneKey(worktreeID: worktreeID, paneID: "%1")
            ))
            #expect(count == 1)
        }
    }
}

// MARK: - Notification arrivals

/// `handleNotificationDelta` (`AppState.swift:2314`) runs once per agent
/// notification — response completions, errors, focus pushes — so its cadence
/// tracks agent output across the whole fleet.
///
/// Both tests keep the delta's worktree VISIBLE (selected), which makes the
/// handler return at `AppState.swift:2335` before it reaches
/// `notificationSoundPlayer.playIfEnabled` and `macNotificationManager`. That
/// is deliberate: driving the full path in a unit test would play a sound and
/// post a system notification on the developer's machine.
@MainActor
@Suite("Notification arrivals")
struct NotificationDeltaTests {

    /// The first arrival for a background-tab terminal — a real change.
    @Test("a background-tab arrival marks the terminal unread")
    func firstArrivalPublishes() {
        withEmissionState { state in
            let repoID = UUID()
            let worktreeID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: worktreeID, repoID: repoID)]]
            state.selectedWorktreeIDs = [worktreeID]
            let backgroundTerminal = UUID()

            let count = countEmissions(of: state) {
                state.handleDelta(.notificationReceived(NotificationDelta(
                    notificationID: UUID(),
                    worktreeID: worktreeID,
                    type: .responseComplete,
                    message: "done",
                    terminalID: backgroundTerminal
                )))
            }

            #expect(state.unreadTerminals.contains(backgroundTerminal))
            #expect(count == 1)
        }
    }

    /// A repeat arrival for a terminal that is already unread. `Set.insert` of
    /// an existing member changes nothing and publishes anyway.
    @Test("a repeat arrival for an already-unread terminal")
    func repeatArrival() {
        withEmissionState { state in
            let repoID = UUID()
            let worktreeID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: worktreeID, repoID: repoID)]]
            state.selectedWorktreeIDs = [worktreeID]
            let backgroundTerminal = UUID()
            let delta = NotificationDelta(
                notificationID: UUID(),
                worktreeID: worktreeID,
                type: .responseComplete,
                message: "done",
                terminalID: backgroundTerminal
            )
            state.handleDelta(.notificationReceived(delta))

            let count = countEmissions(of: state) {
                state.handleDelta(.notificationReceived(delta))
            }

            // KNOWN ISSUE — `AppState.unreadTerminals` (AppState.swift:2331).
            // `Set.insert` is a get-modify-set of the `@Published` property, so
            // an already-unread terminal republishes. Ideal 0, observed 1.
            // Fix: `guard !unreadTerminals.contains(tid)` at the assignment site.
            withKnownIssue("a repeat arrival for an unread terminal republishes (#667)") {
                #expect(count == 0)
            }
        }
    }
}

// MARK: - Remote refresh

/// `refreshRemote` (`AppState+Remote.swift:41`) is the one wholesale-replace
/// refresher in the app with no equality guard at all — every sibling
/// (`refreshRepos`, `refreshWorktrees`, `refreshPRStatuses`, `loadModelProfiles`)
/// compares before assigning. Its real-world cadence is low (a ~60 s daemon-side
/// provider poll plus discrete session lifecycle events), so it is ranked below
/// the delta handlers — but it is the clearest example of the missing guard, and
/// its injectable fetchers make it the one production poll path drivable
/// end-to-end without a daemon.
///
/// Also the case the `async` counter exists for: the two fetches are `await`ed,
/// so a synchronous counter would stop counting at the first suspension.
@MainActor
@Suite("Remote refresh")
struct RemoteRefreshTests {

    @Test("a refresh that returns exactly what is already published")
    func idempotentRemoteRefresh() async {
        let suiteName = "TBDAppTests.AppStateEmissions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(userDefaults: defaults)
        state.remoteProvidersFetcher = { RemoteProvidersResult(providers: []) }
        state.remoteSessionsFetcher = { RemoteSessionsResult(sessions: []) }

        await state.refreshRemote()

        let count = await countEmissions(of: state) {
            await state.refreshRemote()
        }

        // KNOWN ISSUE — ideal 0, observed 7, from five properties across three
        // functions, none of them guarded:
        //   `remoteProviders`, `remoteSessions`     — AppState+Remote.swift:44–45
        //   `unreadByRemoteSession`,
        //   `remoteSessionDisplayNames`             — AppState+Remote.swift:84–85
        //   `explicitlyDetachedRemoteSessions`,
        //   `pendingReconnectRemoteSessions`,
        //   `recentlyAttachedRemoteSessions`        — AppState.swift:1067–1069
        // The five prunes are `x = x.filter { … }`, which is unconditional by
        // construction: `filter` always returns a fresh collection, so the
        // assignment always publishes even when nothing was dropped. And
        // `remoteSessionDisplayNames` has a `didSet` that re-encodes and
        // re-writes UserDefaults (AppState.swift:485), so an idle refresh also
        // costs a disk write.
        // Fix: compare before assigning in all three functions — the shape
        // every sibling refresher already uses.
        withKnownIssue("an unchanged remote refresh publishes 7 times (#667)") {
            #expect(count == 0)
        }
    }
}

// MARK: - Control-mode attach bookkeeping

/// Attach/detach bookkeeping runs on every pane materialization, which the
/// worktree pager does on selection churn as well as on real attaches.
@MainActor
@Suite("Control-mode attach bookkeeping")
struct ControlModeAttachTests {

    @Test("re-attaching the same pane with the same generation")
    func idempotentAttach() {
        withEmissionState { state in
            let worktreeID = UUID()
            state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%1", generation: 7)

            let count = countEmissions(of: state) {
                state.controlModePaneAttached(worktreeID: worktreeID, paneID: "%1", generation: 7)
            }

            // KNOWN ISSUE — `controlModeAttachedPanes` + `controlModeFailingInputPanes`
            // (AppState.swift:2059–2060). Both writes are unconditional, so an
            // idempotent re-attach costs 2. Ideal 0. Fix: guard both at the
            // assignment site.
            withKnownIssue("an idempotent re-attach publishes twice (#667)") {
                #expect(count == 0)
            }
        }
    }

    @Test("detaching a pane that was never attached")
    func detachOfUnknownPane() {
        withEmissionState { state in
            let count = countEmissions(of: state) {
                state.controlModePaneDetached(worktreeID: UUID(), paneID: "%99")
            }

            // KNOWN ISSUE — `controlModeAttachedPanes` + `controlModeFailingInputPanes`
            // (AppState.swift:2083–2084). `removeValue` / `remove` on absent
            // keys still publish. Ideal 0, observed 2. The method's own doc
            // comment calls it idempotent — it is idempotent in *state* but not
            // in *invalidation*, which is precisely the distinction this file
            // exists to make. Fix: guard both at the assignment site.
            withKnownIssue("a no-op detach publishes twice (#667)") {
                #expect(count == 0)
            }
        }
    }

    @Test("a real attach publishes")
    func realAttachPublishes() {
        withEmissionState { state in
            let count = countEmissions(of: state) {
                state.controlModePaneAttached(worktreeID: UUID(), paneID: "%1", generation: 1)
            }

            #expect(count >= 1)
        }
    }
}

// MARK: - Poll-tick composites

/// `refreshWorktrees` runs on a repeat timer and funnels each worktree's
/// terminal list through `adoptTerminalSnapshot`. This is the composite that
/// matters most: an idle fleet must cost nothing per tick.
@MainActor
@Suite("Terminal poll tick")
struct TerminalPollTickTests {

    /// The good case, and the pattern the rest of the app should copy:
    /// `adoptTerminalSnapshot` compares before assigning
    /// (`AppState+Terminals.swift:297`), so an idle poll tick is genuinely
    /// silent. Asserted for real — this is a property to defend, not a defect.
    @Test("an identical snapshot publishes nothing")
    func identicalSnapshotIsSilent() {
        withEmissionState { state in
            let worktreeID = UUID()
            let terminal = makeTerminal(worktreeID: worktreeID)
            seatOneTerminal(state, worktreeID: worktreeID, terminal: terminal)

            let count = countEmissions(of: state) {
                state.adoptTerminalSnapshot([terminal], worktreeID: worktreeID)
            }

            #expect(count == 0)
        }
    }

    /// The bad case behind it. `Terminal` compares unequal whenever an agent's
    /// `activityState` flips — the codebase's own comment at
    /// `AppState+Tabs.swift:117` says this happens "constantly" — so the guard
    /// opens and `reconcileTabs` runs. `reconcileTabs` then assigns
    /// `tabs[worktreeID]` unconditionally (`AppState.swift:2836`) even though
    /// the tab set is byte-identical, and `reconcileNoteTabs` and
    /// `applyStoredOrder` add more writes on the same path.
    @Test("a snapshot whose only change is activity state")
    func activityFlipInSnapshot() {
        withEmissionState { state in
            let worktreeID = UUID()
            let terminalID = UUID()
            seatOneTerminal(
                state,
                worktreeID: worktreeID,
                terminal: makeTerminal(id: terminalID, worktreeID: worktreeID, activityState: .idle)
            )

            let count = countEmissions(of: state) {
                state.adoptTerminalSnapshot(
                    [makeTerminal(id: terminalID, worktreeID: worktreeID, activityState: .working)],
                    worktreeID: worktreeID
                )
            }

            #expect(state.terminals[worktreeID]?.first?.activityState == .working)
            // KNOWN ISSUE — `terminals` (necessary) plus `tabs` (not).
            // Ideal 1: only the terminal row actually changed; the tab array is
            // identical before and after. Observed 2. Fix: an equality guard at
            // `AppState.swift:2836` — `if currentTabs != tabs[worktreeID] {}`.
            withKnownIssue("an activity flip also republishes an unchanged `tabs` (#667)") {
                #expect(count == 1)
            }
        }
    }

    /// `reconcileTabs` in isolation, with nothing to reconcile.
    @Test("reconciling an unchanged tab set")
    func reconcileUnchangedTabs() {
        withEmissionState { state in
            let worktreeID = UUID()
            let terminal = makeTerminal(worktreeID: worktreeID)
            seatOneTerminal(state, worktreeID: worktreeID, terminal: terminal)

            let count = countEmissions(of: state) {
                state.reconcileTabs(worktreeID: worktreeID, terminals: [terminal])
            }

            // KNOWN ISSUE — `AppState.tabs` (AppState.swift:2836). Ideal 0,
            // observed 1: the assignment is unconditional. This is the single
            // highest-frequency unguarded write found, because its caller runs
            // on every terminal-list change and `Terminal` inequality tracks
            // `activityState`. Fix: guard at the assignment site.
            withKnownIssue("reconciling an identical tab set republishes `tabs` (#667)") {
                #expect(count == 0)
            }
        }
    }

    /// The `reconcileTabs` guard must not swallow a real tab addition.
    @Test("reconciling with a new terminal publishes")
    func reconcileWithNewTerminal() {
        withEmissionState { state in
            let worktreeID = UUID()
            let first = makeTerminal(worktreeID: worktreeID)
            seatOneTerminal(state, worktreeID: worktreeID, terminal: first)
            let second = makeTerminal(worktreeID: worktreeID)

            let count = countEmissions(of: state) {
                state.reconcileTabs(worktreeID: worktreeID, terminals: [first, second])
            }

            #expect(state.tabs[worktreeID]?.count == 2)
            #expect(count >= 1)
        }
    }
}

// MARK: - Selection

/// Selection is a user gesture, so its frequency is bounded by clicks — but the
/// `didSet` cascade at `AppState.swift:192` writes five further `@Published`
/// properties unconditionally, so one click costs many invalidations, and
/// re-clicking the already-selected row costs the same as a real move.
@MainActor
@Suite("Selection cascade")
struct SelectionCascadeTests {

    @Test("re-selecting the worktree that is already selected")
    func idempotentSelection() {
        withEmissionState { state in
            let repoID = UUID()
            let row = makeWorktree(repoID: repoID)
            state.worktrees = [repoID: [row]]
            state.isInitialStateLoaded = true
            state.selectedWorktreeIDs = [row.id]

            let count = countEmissions(of: state) {
                state.selectedWorktreeIDs = [row.id]
            }

            // KNOWN ISSUE — ideal 0, observed 7: `selectedWorktreeIDs` itself
            // (1), the four unconditional clears in its own `didSet` tail —
            // `selectedRepoID`, `selectedScratchSection`,
            // `selectedRemoteProvider`, `selectedRemoteSession`
            // (AppState.swift:303–306) — and the `recentWorktreeIDs`
            // `removeAll`/`insert` pair (:316–:317), which rewrites the LRU to
            // the arrangement it already had.
            // `selectionOrder` contributes nothing: its write IS guarded
            // (:292), which is the model the other six should follow.
            withKnownIssue("re-selecting the current worktree costs 7 publishes (#667)") {
                #expect(count == 0)
            }
        }
    }

    /// A real selection change. Not zero, and not one either — the number is the
    /// finding. Pinned as a live assertion so the cascade cannot silently grow.
    ///
    /// The 9 accounted for in full, because an unattributed total invites a
    /// reader to "fix" the wrong line: `selectedWorktreeIDs` (1) +
    /// `selectionOrder` (1) + the four unconditional clears at
    /// `AppState.swift:303`–`:306` (4) + `canGoBack`, flipped to true by
    /// `recordNavigation` because this is the second entry in the history (1) +
    /// the `recentWorktreeIDs` `removeAll`/`insert` pair at `:316`–`:317` (2).
    @Test("selecting a different worktree")
    func realSelectionChange() {
        withEmissionState { state in
            let repoID = UUID()
            let rows = (0..<2).map { makeWorktree(repoID: repoID, sortOrder: $0) }
            state.worktrees = [repoID: rows]
            state.isInitialStateLoaded = true
            state.selectedWorktreeIDs = [rows[0].id]

            let count = countEmissions(of: state) {
                state.selectedWorktreeIDs = [rows[1].id]
            }

            #expect(state.selectionOrder == [rows[1].id])
            #expect(count == 9)
        }
    }

    /// Selecting five rows in one gesture. The cascade is per-*assignment*, not
    /// per-id, so this must not scale with N — the guard-rail against a
    /// regression back to the per-id mutation `SelectionOrderWriteCoalescingTests`
    /// removed.
    ///
    /// 8, one fewer than the test above, and the missing one is `canGoBack`:
    /// this is the FIRST navigation entry, so there is nothing to go back to
    /// and `updateNavigationFlags` leaves the flag alone. That guard
    /// (`AppState.swift:413`) is one of the few already in the right place.
    @Test("selecting five worktrees in one gesture")
    func multiSelection() {
        withEmissionState { state in
            let repoID = UUID()
            let rows = (0..<5).map { makeWorktree(repoID: repoID, sortOrder: $0) }
            state.worktrees = [repoID: rows]
            state.isInitialStateLoaded = true

            let count = countEmissions(of: state) {
                state.selectedWorktreeIDs = Set(rows.map(\.id))
            }

            #expect(state.selectedWorktreeIDs.count == 5)
            #expect(count == 8)
        }
    }
}
