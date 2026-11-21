import Testing
import Foundation
import TBDShared
@testable import TBDApp
import TestSupport

/// Per-suite UserDefaults so tests don't clobber the developer's real TBDApp.plist.
/// See CLAUDE.md → "Tests must not touch ~/tbd".
@MainActor
private func makeIsolatedAppState() -> (AppState, TestDefaultsSuite) {
    let suite = TestDefaultsSuite("com.tbd.tests.notificationclick")
    let defaults = suite.defaults
    let state = AppState(userDefaults: defaults)
    return (state, suite)
}

@MainActor
private func tearDown(_ suite: TestDefaultsSuite) {
    suite.tearDown()
}

@MainActor
@Test func handleClick_validUUID_selectsWorktree() async {
    let (appState, suite) = makeIsolatedAppState()
    defer { tearDown(suite) }
    appState.isInitialStateLoaded = true
    let id = UUID()
    let repoID = UUID()
    appState.worktrees = [
        repoID: [
            Worktree(id: id, repoID: repoID, name: "x", displayName: "X",
                     branch: "tbd/x", path: "/tmp/x", tmuxServer: "tbd-x"),
        ],
    ]

    appState.macNotificationManager.handleClick(identifier: id.uuidString)

    #expect(appState.selectedWorktreeIDs == [id])
}

@MainActor
@Test func handleClick_malformedIdentifier_doesNotMutateSelection() async {
    let (appState, suite) = makeIsolatedAppState()
    defer { tearDown(suite) }
    appState.isInitialStateLoaded = true
    let id = UUID()
    let repoID = UUID()
    appState.worktrees = [
        repoID: [
            Worktree(id: id, repoID: repoID, name: "x", displayName: "X",
                     branch: "tbd/x", path: "/tmp/x", tmuxServer: "tbd-x"),
        ],
    ]
    appState.selectedWorktreeIDs = []

    appState.macNotificationManager.handleClick(identifier: "not-a-uuid")

    #expect(appState.selectedWorktreeIDs.isEmpty)
}

@MainActor
@Test func handleClick_withoutConfiguredAppState_doesNotCrash() async {
    // A bare manager with no configure() call — proves the guard works.
    let manager = MacNotificationManager()

    manager.handleClick(identifier: UUID().uuidString)

    #expect(manager.appState == nil)
}

// MARK: - dismissDelivered tests

@MainActor
@Test func dismissDelivered_emptySequence_doesNotCrash() async {
    // Empty input must be a no-op — no assertion, just verify no crash or
    // precondition failure.
    let manager = MacNotificationManager()
    manager.dismissDelivered(worktreeIDs: [] as [UUID])
}

@MainActor
@Test func dismissDelivered_nonEmptyOnUnbundled_doesNotCrash() async {
    // In the unbundled test process, isAvailable is false, so the call
    // returns early without touching UNUserNotificationCenter.
    let manager = MacNotificationManager()
    let ids = [UUID(), UUID(), UUID()]
    manager.dismissDelivered(worktreeIDs: ids)
    // If we reach here without crashing, the guard is working correctly.
}

@MainActor
@Test func dismissDelivered_singleID_doesNotCrash() async {
    let manager = MacNotificationManager()
    manager.dismissDelivered(worktreeIDs: [UUID()])
}

// MARK: - terminalID routing tests

/// Build a fixture appState with one worktree and a two-tab layout. The
/// second tab is a `.terminal(terminalID:)` pane for `terminalID` so tests
/// can verify the click handler selects it.
@MainActor
private func makeAppStateWithTabs(
    worktreeID: UUID,
    repoID: UUID,
    terminalID: UUID
) -> (AppState, TestDefaultsSuite) {
    let (state, suite) = makeIsolatedAppState()
    state.isInitialStateLoaded = true
    state.worktrees = [
        repoID: [
            Worktree(id: worktreeID, repoID: repoID, name: "x", displayName: "X",
                     branch: "tbd/x", path: "/tmp/x", tmuxServer: "tbd-x"),
        ],
    ]
    let tab0 = Tab(id: UUID(), content: .terminal(terminalID: UUID()), label: nil)
    let tab1 = Tab(id: UUID(), content: .terminal(terminalID: terminalID), label: nil)
    state.tabs[worktreeID] = [tab0, tab1]
    state.activeTabIndices[worktreeID] = 0
    return (state, suite)
}

@MainActor
@Test func handleClick_withTerminalID_setsActiveTab() async {
    let worktreeID = UUID()
    let repoID = UUID()
    let terminalID = UUID()
    let (appState, suite) = makeAppStateWithTabs(
        worktreeID: worktreeID, repoID: repoID, terminalID: terminalID
    )
    defer { tearDown(suite) }

    appState.macNotificationManager.handleClick(
        worktreeID: worktreeID, terminalID: terminalID
    )

    #expect(appState.selectedWorktreeIDs == [worktreeID])
    #expect(appState.activeTabIndices[worktreeID] == 1)
}

@MainActor
@Test func handleClick_withTerminalID_terminalNotInTabs_fallsBackSilently() async {
    let worktreeID = UUID()
    let repoID = UUID()
    let terminalID = UUID()
    let (appState, suite) = makeAppStateWithTabs(
        worktreeID: worktreeID, repoID: repoID, terminalID: terminalID
    )
    defer { tearDown(suite) }

    // Pass a terminal ID that isn't in any tab.
    let strangerID = UUID()
    appState.macNotificationManager.handleClick(
        worktreeID: worktreeID, terminalID: strangerID
    )

    // Selection still set; active tab unchanged (remains 0 from setup).
    #expect(appState.selectedWorktreeIDs == [worktreeID])
    #expect(appState.activeTabIndices[worktreeID] == 0)
}

@MainActor
@Test func handleClick_withoutTerminalID_behavesAsBefore() async {
    let worktreeID = UUID()
    let repoID = UUID()
    let terminalID = UUID()
    let (appState, suite) = makeAppStateWithTabs(
        worktreeID: worktreeID, repoID: repoID, terminalID: terminalID
    )
    defer { tearDown(suite) }

    appState.macNotificationManager.handleClick(
        worktreeID: worktreeID, terminalID: nil
    )

    // Selection set, active tab unchanged.
    #expect(appState.selectedWorktreeIDs == [worktreeID])
    #expect(appState.activeTabIndices[worktreeID] == 0)
}

@MainActor
@Test func handleClick_withTerminalID_matchesLiveTranscriptTab() async {
    // Mirror of `handleClick_withTerminalID_setsActiveTab` but the second
    // tab is a `.liveTranscript` pane — both arms of the tab-match switch
    // should select the originating terminal's surface.
    let worktreeID = UUID()
    let repoID = UUID()
    let terminalID = UUID()
    let (appState, suite) = makeIsolatedAppState()
    defer { tearDown(suite) }
    appState.isInitialStateLoaded = true
    appState.worktrees = [
        repoID: [
            Worktree(id: worktreeID, repoID: repoID, name: "x", displayName: "X",
                     branch: "tbd/x", path: "/tmp/x", tmuxServer: "tbd-x"),
        ],
    ]
    let tab0 = Tab(id: UUID(), content: .terminal(terminalID: UUID()), label: nil)
    let tab1 = Tab(id: UUID(),
                   content: .liveTranscript(id: UUID(), terminalID: terminalID),
                   label: nil)
    appState.tabs[worktreeID] = [tab0, tab1]
    appState.activeTabIndices[worktreeID] = 0

    appState.macNotificationManager.handleClick(
        worktreeID: worktreeID, terminalID: terminalID
    )

    #expect(appState.selectedWorktreeIDs == [worktreeID])
    #expect(appState.activeTabIndices[worktreeID] == 1)
}

@MainActor
@Test func handleClick_userInfoTerminalIDString_routesToTab() async {
    // Mirrors the string-parsing path used by the UN delegate callback.
    let worktreeID = UUID()
    let repoID = UUID()
    let terminalID = UUID()
    let (appState, suite) = makeAppStateWithTabs(
        worktreeID: worktreeID, repoID: repoID, terminalID: terminalID
    )
    defer { tearDown(suite) }

    appState.macNotificationManager.handleClick(
        identifier: worktreeID.uuidString,
        terminalIDString: terminalID.uuidString
    )

    #expect(appState.activeTabIndices[worktreeID] == 1)
}

// MARK: - Remote session banner tests

private func remoteSession(
    provider: String = "acme", sessionID: String,
    resolvedRepoID: UUID? = nil, dismissed: Bool = false
) -> RemoteSessionInfo {
    RemoteSessionInfo(
        provider: provider, payload: RemoteSessionPayload(id: sessionID, state: .running),
        gone: false, dismissed: dismissed, lastSeen: Date(), resolvedRepoID: resolvedRepoID)
}

/// A loaded appState whose remote mirror reports `acme`/`sessionID`.
@MainActor
private func makeAppStateWithRemoteSession(
    sessionID: String = "s1", resolvedRepoID: UUID? = nil, dismissed: Bool = false
) -> (AppState, TestDefaultsSuite) {
    let (state, suite) = makeIsolatedAppState()
    state.isInitialStateLoaded = true
    state.remoteMirrorLoaded = true
    state.remoteSessions = [
        remoteSession(sessionID: sessionID, resolvedRepoID: resolvedRepoID, dismissed: dismissed),
    ]
    return (state, suite)
}

/// Clicks a banner the way the delegate does for one posted by
/// `postRemoteAttention`: its identifier and its userInfo, read as strings.
@MainActor
private func clickPostedRemoteBanner(
    _ appState: AppState, provider: String = "acme", sessionID: String
) {
    let userInfo = MacNotificationManager.remoteBannerUserInfo(provider: provider, sessionID: sessionID)
    appState.macNotificationManager.handleClick(
        identifier: MacNotificationManager.remoteBannerIdentifier(provider: provider, sessionID: sessionID),
        terminalIDString: nil,
        remoteProvider: userInfo[MacNotificationManager.remoteProviderUserInfoKey],
        remoteSessionID: userInfo[MacNotificationManager.remoteSessionIDUserInfoKey])
}

/// A local worktree, selected, so a test can tell whether a click moved
/// the selection off it.
@MainActor
private func selectLocalWorktree(in appState: AppState) -> UUID {
    let id = UUID()
    let repoID = UUID()
    appState.worktrees[repoID] = [
        Worktree(id: id, repoID: repoID, name: "x", displayName: "X",
                 branch: "tbd/x", path: "/tmp/x", tmuxServer: "tbd-x"),
    ]
    appState.selectedWorktreeIDs = [id]
    return id
}

@Test func remoteBanner_requestCarriesProviderAndSessionID() {
    #expect(MacNotificationManager.remoteBannerIdentifier(provider: "acme", sessionID: "s1")
        == "remote:acme:s1")
    #expect(MacNotificationManager.remoteBannerUserInfo(provider: "acme", sessionID: "s1") == [
        MacNotificationManager.remoteProviderUserInfoKey: "acme",
        MacNotificationManager.remoteSessionIDUserInfoKey: "s1",
    ])
}

@Test func remoteClickTarget_prefersUserInfoOverTheIdentifier() {
    // A provider name may contain `:`; only userInfo carries it intact.
    let identifier = MacNotificationManager.remoteBannerIdentifier(provider: "acme:eu", sessionID: "s1")
    #expect(MacNotificationManager.remoteClickTarget(
        identifier: identifier, provider: "acme:eu", sessionID: "s1")
        == RemoteSessionSelection(provider: "acme:eu", sessionID: "s1"))
}

@Test func remoteClickTarget_parsesTheIdentifierAtTheFirstColon() {
    #expect(MacNotificationManager.remoteClickTarget(
        identifier: "remote:acme:run:42:a", provider: nil, sessionID: nil)
        == RemoteSessionSelection(provider: "acme", sessionID: "run:42:a"))
    // Present but empty userInfo values fall back to the identifier too.
    #expect(MacNotificationManager.remoteClickTarget(
        identifier: "remote:acme:s1", provider: "", sessionID: "")
        == RemoteSessionSelection(provider: "acme", sessionID: "s1"))
}

@Test func remoteClickTarget_isNilForAMalformedIdentifier() {
    for identifier in ["remote:", "remote:acme", "remote::s1", "remote:acme:", "acme:s1"] {
        #expect(MacNotificationManager.remoteClickTarget(
            identifier: identifier, provider: nil, sessionID: nil) == nil)
    }
}

@MainActor
@Test func handleClick_remoteWithUserInfo_selectsSession() async {
    let (appState, suite) = makeAppStateWithRemoteSession()
    defer { tearDown(suite) }
    _ = selectLocalWorktree(in: appState)

    clickPostedRemoteBanner(appState, sessionID: "s1")

    let expected = RemoteSessionSelection(provider: "acme", sessionID: "s1")
    #expect(appState.selectedRemoteSession == expected)
    #expect(appState.selectedWorktreeIDs.isEmpty)
    #expect(appState.navigationEntries.last == NavigationEntry.remoteSession(expected))
}

@MainActor
@Test func handleClick_remoteIdentifierOnly_selectsSession() async {
    // A banner posted without the userInfo keys: the identifier is parsed.
    let (appState, suite) = makeAppStateWithRemoteSession()
    defer { tearDown(suite) }

    appState.macNotificationManager.handleClick(identifier: "remote:acme:s1")

    let expected = RemoteSessionSelection(provider: "acme", sessionID: "s1")
    #expect(appState.selectedRemoteSession == expected)
    #expect(appState.selectedWorktreeIDs.isEmpty)
    #expect(appState.navigationEntries == [.remoteSession(expected)])
}

@MainActor
@Test func handleClick_remoteSessionIDWithColons_roundTripsThroughUserInfo() async {
    let sessionID = "run:2026:abc"
    let (appState, suite) = makeAppStateWithRemoteSession(sessionID: sessionID)
    defer { tearDown(suite) }

    clickPostedRemoteBanner(appState, sessionID: sessionID)

    #expect(appState.selectedRemoteSession
        == RemoteSessionSelection(provider: "acme", sessionID: sessionID))
}

@MainActor
@Test func handleClick_remoteAdoptedLane_selectsTheLaneRow() async {
    let (appState, suite) = makeIsolatedAppState()
    defer { tearDown(suite) }
    appState.isInitialStateLoaded = true
    let repoID = UUID()
    // Shaped like `RemoteSessionAdopter` mints them.
    let lane = Worktree(
        repoID: repoID, name: "remote://acme/s1", displayName: "lane",
        branch: "", path: "remote://acme/s1", tmuxServer: "",
        location: .remote(provider: "acme", sessionID: "s1"))
    appState.worktrees = [repoID: [lane]]
    appState.remoteMirrorLoaded = true
    appState.remoteSessions = [remoteSession(sessionID: "s1", resolvedRepoID: repoID)]

    clickPostedRemoteBanner(appState, sessionID: "s1")

    #expect(appState.selectedWorktreeIDs == [lane.id])
    #expect(appState.selectedRemoteSession == RemoteSessionSelection(provider: "acme", sessionID: "s1"))
}

@MainActor
@Test func handleClick_remoteUnknownSession_leavesSelectionAndShowsErrorToast() async {
    let (appState, suite) = makeAppStateWithRemoteSession()
    defer { tearDown(suite) }
    let worktreeID = selectLocalWorktree(in: appState)
    let entriesBefore = appState.navigationEntries

    clickPostedRemoteBanner(appState, sessionID: "missing")

    #expect(appState.selectedWorktreeIDs == [worktreeID])
    #expect(appState.selectedRemoteSession == nil)
    #expect(appState.navigationEntries == entriesBefore)
    #expect(appState.pendingRemoteSessionLink == nil)
    #expect(appState.activeToast?.style == .error)
    #expect(appState.activeToast?.message == "Remote session not found — it may have ended.")
}

@MainActor
@Test func handleClick_remoteDismissedSession_isTreatedAsUnknown() async {
    // Back/forward skips a dismissed session; a banner click does too.
    let (appState, suite) = makeAppStateWithRemoteSession(dismissed: true)
    defer { tearDown(suite) }

    clickPostedRemoteBanner(appState, sessionID: "s1")

    #expect(appState.selectedRemoteSession == nil)
    #expect(appState.activeToast?.style == .error)
}

@MainActor
@Test func handleClick_remoteMalformedIdentifier_changesNothing() async {
    let (appState, suite) = makeAppStateWithRemoteSession()
    defer { tearDown(suite) }
    let worktreeID = selectLocalWorktree(in: appState)
    let entriesBefore = appState.navigationEntries

    for identifier in ["remote:", "remote:acme", "remote::s1"] {
        appState.macNotificationManager.handleClick(identifier: identifier)
    }

    #expect(appState.selectedWorktreeIDs == [worktreeID])
    #expect(appState.selectedRemoteSession == nil)
    #expect(appState.navigationEntries == entriesBefore)
    #expect(appState.activeToast == nil)
}

@MainActor
@Test func handleClick_remoteSessionInCollapsedRepo_expandsTheRepo() async {
    let repoID = UUID()
    let (appState, suite) = makeAppStateWithRemoteSession(resolvedRepoID: repoID)
    defer { tearDown(suite) }
    appState.repos = [Repo(id: repoID, path: "/tmp/x", displayName: "x", expanded: false)]

    clickPostedRemoteBanner(appState, sessionID: "s1")

    #expect(appState.selectedRemoteSession == RemoteSessionSelection(provider: "acme", sessionID: "s1"))
    #expect(appState.repos.first?.expanded == true)
}

@MainActor
@Test func handleClick_remoteBeforeInitialLoad_selectsOnceTheMirrorLoads() async {
    let (appState, suite) = makeIsolatedAppState()
    defer { tearDown(suite) }
    // Default: isInitialStateLoaded == false and the mirror is empty.

    clickPostedRemoteBanner(appState, sessionID: "s1")

    let expected = RemoteSessionSelection(provider: "acme", sessionID: "s1")
    #expect(appState.pendingRemoteSessionLink == expected)
    #expect(appState.selectedRemoteSession == nil)
    #expect(appState.activeToast == nil)

    // What `connectAndLoadInitialState` does: the first remote refresh fills
    // the mirror but replays nothing, because the load has not finished;
    // the load completes, and the held click is replayed.
    stubRemoteLoad(appState, sessions: [remoteSession(sessionID: "s1")])
    await appState.refreshRemote()
    #expect(appState.pendingRemoteSessionLink == expected)
    #expect(appState.selectedRemoteSession == nil)

    appState.isInitialStateLoaded = true
    appState.drainPendingRemoteSessionLink()

    #expect(appState.selectedRemoteSession == expected)
    #expect(appState.pendingRemoteSessionLink == nil)
    #expect(appState.activeToast == nil)
}

/// Installs remote fetchers on `appState`, so `refreshRemote()` runs its real
/// paths with no daemon: the given failure when there is one, else the
/// daemon's answer with `sessions`.
@MainActor
private func stubRemoteLoad(
    _ appState: AppState, failure: DaemonClientError? = nil, sessions: [RemoteSessionInfo] = []
) {
    appState.remoteProvidersFetcher = {
        if let failure { throw failure }
        return RemoteProvidersResult(providers: [])
    }
    appState.remoteSessionsFetcher = {
        if let failure { throw failure }
        return RemoteSessionsResult(sessions: sessions)
    }
    appState.retainedTranscriptsFetcher = { [] }
}

/// Writes the selection a relaunch restores when no click is held, where
/// `restoreSavedSelection` reads it.
private func writeSavedSelection(_ ids: [UUID], to defaults: UserDefaults) {
    if let data = try? JSONEncoder().encode(ids.map(\.uuidString)) {
        defaults.set(data, forKey: "com.tbd.app.selectionOrder")
    }
}

/// An active local worktree in `appState`, not selected.
@MainActor
private func addLocalWorktree(to appState: AppState) -> UUID {
    let id = UUID()
    let repoID = UUID()
    appState.worktrees[repoID] = [
        Worktree(id: id, repoID: repoID, name: "x", displayName: "X",
                 branch: "tbd/x", path: "/tmp/x", tmuxServer: "tbd-x"),
    ]
    return id
}

@MainActor
@Test func handleClick_remoteHeldAcrossAFailedRemoteLoad_isReplayedByTheNextLoadThatSucceeds() async {
    let (appState, suite) = makeIsolatedAppState()
    defer { tearDown(suite) }
    let savedID = addLocalWorktree(to: appState)
    writeSavedSelection([savedID], to: suite.defaults)
    let expected = RemoteSessionSelection(provider: "acme", sessionID: "s1")

    clickPostedRemoteBanner(appState, sessionID: "s1")

    // `connectAndLoadInitialState`, connected, whose remote refresh fails:
    // the load completes, and the click stays held rather than being
    // answered "not found" against the empty mirror.
    stubRemoteLoad(appState, failure: .connectionFailed("acme down"))
    appState.restoreSavedSelection(validWorktreeIDs: appState.allWorktrees.map(\.id))
    await appState.refreshRemote()
    appState.isInitialStateLoaded = true
    appState.drainPendingRemoteSessionLink()

    #expect(appState.pendingRemoteSessionLink == expected)
    #expect(appState.activeToast == nil)
    #expect(appState.selectedRemoteSession == nil)

    // Its next run: the saved selection is not restored over the held click,
    // and the remote refresh, which now succeeds, replays the click.
    stubRemoteLoad(appState, sessions: [remoteSession(sessionID: "s1")])
    appState.restoreSavedSelection(validWorktreeIDs: appState.allWorktrees.map(\.id))
    #expect(appState.selectedWorktreeIDs.isEmpty)
    await appState.refreshRemote()

    #expect(appState.selectedRemoteSession == expected)
    #expect(appState.pendingRemoteSessionLink == nil)
    #expect(appState.navigationEntries == [.remoteSession(expected)])
    #expect(appState.activeToast == nil)
}

@MainActor
@Test func handleClick_remoteAfterALaunchThatCouldNotConnect_isHeldInPlaceOfTheEarlierClick() async {
    let (appState, suite) = makeIsolatedAppState()
    defer { tearDown(suite) }
    clickPostedRemoteBanner(appState, sessionID: "s1")

    // `connectAndLoadInitialState` with no daemon: no refresh runs, but the
    // load completes and drains. The click stays held.
    appState.isInitialStateLoaded = true
    appState.drainPendingRemoteSessionLink()
    #expect(appState.pendingRemoteSessionLink == RemoteSessionSelection(provider: "acme", sessionID: "s1"))
    #expect(appState.activeToast == nil)

    // A click after that launch is held too, in place of the earlier one.
    clickPostedRemoteBanner(appState, sessionID: "s2")
    let later = RemoteSessionSelection(provider: "acme", sessionID: "s2")
    #expect(appState.pendingRemoteSessionLink == later)
    #expect(appState.selectedRemoteSession == nil)
    #expect(appState.activeToast == nil)

    // The reconnect's remote load replays the later click.
    stubRemoteLoad(appState, sessions: [remoteSession(sessionID: "s1"), remoteSession(sessionID: "s2")])
    await appState.refreshRemote()

    #expect(appState.selectedRemoteSession == later)
    #expect(appState.pendingRemoteSessionLink == nil)
    #expect(appState.navigationEntries == [.remoteSession(later)])
}

@MainActor
@Test func handleClick_remoteHeldUntilTheDaemonSaysRemoteIsOff_isAnsweredNotFound() async {
    // The feature being off is an answer too: no session exists.
    let (appState, suite) = makeIsolatedAppState()
    defer { tearDown(suite) }
    appState.isInitialStateLoaded = true
    clickPostedRemoteBanner(appState, sessionID: "s1")
    #expect(appState.pendingRemoteSessionLink != nil)

    stubRemoteLoad(appState, failure: .rpcError(AppState.remoteBackendsDisabledMessage, code: nil))
    await appState.refreshRemote()

    #expect(appState.remoteMirrorLoaded)
    #expect(appState.pendingRemoteSessionLink == nil)
    #expect(appState.selectedRemoteSession == nil)
    #expect(appState.activeToast?.message == "Remote session not found — it may have ended.")
}

@MainActor
@Test func navigateToWorktree_afterAFailedLaunch_dropsAHeldRemoteClick() async {
    // The later click wins after a failed launch as before one: a remote
    // load that succeeds later must not replay the earlier banner click.
    let (appState, suite) = makeIsolatedAppState()
    defer { tearDown(suite) }
    appState.isInitialStateLoaded = true
    let worktreeID = addLocalWorktree(to: appState)
    clickPostedRemoteBanner(appState, sessionID: "s1")
    #expect(appState.pendingRemoteSessionLink != nil)

    appState.navigateToWorktree(worktreeID)
    #expect(appState.pendingRemoteSessionLink == nil)

    stubRemoteLoad(appState, sessions: [remoteSession(sessionID: "s1")])
    await appState.refreshRemote()

    #expect(appState.selectedWorktreeIDs == [worktreeID])
    #expect(appState.selectedRemoteSession == nil)
}

@MainActor
@Test func heldRemoteClick_isDroppedByALaterSidebarSelection() async {
    let (appState, suite) = makeIsolatedAppState()
    defer { tearDown(suite) }
    appState.isInitialStateLoaded = true
    let worktreeID = addLocalWorktree(to: appState)
    clickPostedRemoteBanner(appState, sessionID: "s1")
    #expect(appState.pendingRemoteSessionLink != nil)

    // What the sidebar outline and the dock write for a user's row click
    // (`writeSelection`).
    appState.selectedWorktreeIDs = [worktreeID]
    #expect(appState.pendingRemoteSessionLink == nil)

    stubRemoteLoad(appState, sessions: [remoteSession(sessionID: "s1")])
    await appState.refreshRemote()

    #expect(appState.selectedWorktreeIDs == [worktreeID])
    #expect(appState.selectedRemoteSession == nil)
}

@MainActor
@Test func heldRemoteClick_isDroppedByALaterBackNavigation() async {
    let (appState, suite) = makeIsolatedAppState()
    defer { tearDown(suite) }
    appState.isInitialStateLoaded = true
    let first = addLocalWorktree(to: appState)
    let second = addLocalWorktree(to: appState)
    appState.selectedWorktreeIDs = [first]
    appState.selectedWorktreeIDs = [second]
    clickPostedRemoteBanner(appState, sessionID: "s1")
    #expect(appState.pendingRemoteSessionLink != nil)

    appState.navigateBack()
    #expect(appState.selectedWorktreeIDs == [first])
    #expect(appState.pendingRemoteSessionLink == nil)

    stubRemoteLoad(appState, sessions: [remoteSession(sessionID: "s1")])
    await appState.refreshRemote()

    #expect(appState.selectedWorktreeIDs == [first])
    #expect(appState.selectedRemoteSession == nil)
}

@MainActor
@Test func heldRemoteClick_isDroppedByALaterHeaderClick() async {
    // The Scratch and provider headers record no history entry.
    let (appState, suite) = makeIsolatedAppState()
    defer { tearDown(suite) }
    appState.isInitialStateLoaded = true

    clickPostedRemoteBanner(appState, sessionID: "s1")
    appState.selectScratchSection()
    #expect(appState.pendingRemoteSessionLink == nil)

    clickPostedRemoteBanner(appState, sessionID: "s1")
    appState.selectRemoteProvider("acme")
    #expect(appState.pendingRemoteSessionLink == nil)

    stubRemoteLoad(appState, sessions: [remoteSession(sessionID: "s1")])
    await appState.refreshRemote()

    #expect(appState.selectedRemoteSession == nil)
}

/// Counts the remote fetches a `refreshRemote()` makes. A class, because
/// the fetchers are escaping closures and cannot mutate a captured `var`.
@MainActor
private final class RemoteFetchCount {
    var value = 0
}

@MainActor
@Test func pollTickReconnect_loadsTheRemoteListAndAnswersAHeldClick() async {
    let (appState, suite) = makeIsolatedAppState()
    defer { tearDown(suite) }
    clickPostedRemoteBanner(appState, sessionID: "s1")
    // The launch completed without connecting, so nothing loaded the mirror.
    appState.isInitialStateLoaded = true
    appState.drainPendingRemoteSessionLink()
    stubRemoteLoad(appState, sessions: [remoteSession(sessionID: "s1")])

    await appState.pollTickDidReconnect()

    #expect(appState.remoteMirrorLoaded)
    #expect(appState.selectedRemoteSession == RemoteSessionSelection(provider: "acme", sessionID: "s1"))
    #expect(appState.pendingRemoteSessionLink == nil)
}

@MainActor
@Test func pollTickReconnect_leavesALoadedRemoteListToItsUsualRefresh() async {
    let (appState, suite) = makeIsolatedAppState()
    defer { tearDown(suite) }
    appState.remoteMirrorLoaded = true
    let fetches = RemoteFetchCount()
    appState.remoteProvidersFetcher = {
        fetches.value += 1
        return RemoteProvidersResult(providers: [])
    }
    appState.remoteSessionsFetcher = {
        fetches.value += 1
        return RemoteSessionsResult(sessions: [])
    }
    appState.retainedTranscriptsFetcher = { [] }

    await appState.pollTickDidReconnect()

    #expect(fetches.value == 0)
}

@MainActor
@Test func heldClicksBeforeInitialLoad_theLaterOneWins() async {
    let (appState, suite) = makeIsolatedAppState()
    defer { tearDown(suite) }
    let worktreeID = UUID()

    appState.navigateToWorktree(worktreeID)
    clickPostedRemoteBanner(appState, sessionID: "s1")
    #expect(appState.pendingDeepLinkID == nil)
    #expect(appState.pendingRemoteSessionLink == RemoteSessionSelection(provider: "acme", sessionID: "s1"))

    appState.navigateToWorktree(worktreeID)
    #expect(appState.pendingDeepLinkID == worktreeID)
    #expect(appState.pendingRemoteSessionLink == nil)
}
