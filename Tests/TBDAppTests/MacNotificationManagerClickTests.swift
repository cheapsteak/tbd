import Testing
import Foundation
import TBDShared
@testable import TBDApp

/// Per-suite UserDefaults so tests don't clobber the developer's real TBDApp.plist.
/// See CLAUDE.md → "Tests must not touch ~/tbd".
@MainActor
private func makeIsolatedAppState() -> (AppState, String) {
    let suiteName = "com.tbd.tests.notificationclick.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let state = AppState(userDefaults: defaults)
    return (state, suiteName)
}

@MainActor
private func tearDown(_ suiteName: String) {
    UserDefaults().removePersistentDomain(forName: suiteName)
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
) -> (AppState, String) {
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
