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
