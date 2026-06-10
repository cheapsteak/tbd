import Testing
import Foundation
import TBDShared
@testable import TBDApp

// MARK: - Helpers

@MainActor
private func makeIsolatedAppState() -> (AppState, String) {
    let suiteName = "com.tbd.tests.deeplink.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    return (AppState(userDefaults: defaults), suiteName)
}

@MainActor
private func tearDown(_ suiteName: String) {
    UserDefaults().removePersistentDomain(forName: suiteName)
}

// MARK: - Tests

@MainActor
@Test func handle_knownActiveUUID_selectsWorktree() async {
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
    let url = DeepLink.makeOpenWorktreeURL(id)

    DeepLinkHandler.handle(url, appState: appState)

    #expect(appState.selectedWorktreeIDs == [id])
}

@MainActor
@Test func handle_unknownUUID_doesNotMutateSelection() async {
    let (appState, suite) = makeIsolatedAppState()
    defer { tearDown(suite) }
    appState.isInitialStateLoaded = true
    appState.worktrees = [:]
    appState.archivedLookupOverride = { _ in [] }
    let url = DeepLink.makeOpenWorktreeURL(UUID())

    DeepLinkHandler.handle(url, appState: appState)

    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(appState.selectedWorktreeIDs.isEmpty)
    #expect(appState.selectedRepoID == nil)
}

@MainActor
@Test func handle_malformedURL_doesNotMutateSelection() async {
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
    let url = URL(string: "https://wrong-scheme/?worktree=\(id.uuidString)")!

    DeepLinkHandler.handle(url, appState: appState)

    #expect(appState.selectedWorktreeIDs.isEmpty)
}

@MainActor
@Test func handle_archivedUUID_opensArchivedPaneAndHighlightsRow() async {
    let (appState, suite) = makeIsolatedAppState()
    defer { tearDown(suite) }
    appState.isInitialStateLoaded = true
    let repoID = UUID()
    let archivedID = UUID()
    let archivedWT = Worktree(
        id: archivedID, repoID: repoID, name: "old", displayName: "Old",
        branch: "tbd/old", path: "/tmp/old", status: .archived,
        tmuxServer: "tbd-old"
    )
    // Test seam: short-circuit the daemon RPC.
    appState.archivedLookupOverride = { _ in [archivedWT] }
    appState.worktrees = [:] // active miss

    let url = DeepLink.makeOpenWorktreeURL(archivedID)
    DeepLinkHandler.handle(url, appState: appState)

    // navigateToArchivedWorktree is async — wait for it to settle.
    try? await Task.sleep(nanoseconds: 50_000_000)

    #expect(appState.selectedRepoID == repoID)
    #expect(appState.highlightedArchivedWorktreeID == archivedID)
    #expect(appState.selectedWorktreeIDs.isEmpty)
    #expect(appState.archivedWorktrees[repoID]?.contains(where: { $0.id == archivedID }) == true)
}

@MainActor
@Test func navigateToActive_clearsArchivedHighlight() async {
    let appState = AppState()
    let id = UUID()
    appState.worktrees = [
        UUID(): [Worktree(id: id, repoID: UUID(), name: "x", displayName: "X",
                          branch: "tbd/x", path: "/tmp/x", tmuxServer: "tbd-x")]
    ]
    appState.highlightedArchivedWorktreeID = UUID()  // stale highlight from a prior archived link

    appState.navigateToActiveWorktree(id)

    #expect(appState.highlightedArchivedWorktreeID == nil)
    #expect(appState.selectedWorktreeIDs == [id])
}

@MainActor
@Test func navigateToActive_setsPendingScrollTarget() async {
    let appState = AppState()
    let repoID = UUID()
    let id = UUID()
    appState.repos = [Repo(id: repoID, path: "/tmp/r", displayName: "R")]
    appState.worktrees = [
        repoID: [Worktree(id: id, repoID: repoID, name: "x", displayName: "X",
                          branch: "tbd/x", path: "/tmp/x", tmuxServer: "tbd-x")]
    ]

    appState.navigateToActiveWorktree(id)

    #expect(appState.pendingScrollToWorktreeID == id)
}

@MainActor
@Test func navigateToActive_expandsContainingRepoIfCollapsed() async {
    let appState = AppState()
    let repoID = UUID()
    let id = UUID()
    appState.repos = [Repo(id: repoID, path: "/tmp/r", displayName: "R", expanded: false)]
    appState.worktrees = [
        repoID: [Worktree(id: id, repoID: repoID, name: "x", displayName: "X",
                          branch: "tbd/x", path: "/tmp/x", tmuxServer: "tbd-x")]
    ]

    appState.navigateToActiveWorktree(id)

    #expect(appState.repos.first(where: { $0.id == repoID })?.expanded == true)
}

@MainActor
@Test func navigateToWorktree_beforeInitialLoad_buffersID() async {
    let appState = AppState()
    let id = UUID()
    // Default: isInitialStateLoaded == false on a fresh AppState.
    appState.worktrees = [:]

    appState.navigateToWorktree(id)

    #expect(appState.pendingDeepLinkID == id)
    #expect(appState.selectedWorktreeIDs.isEmpty)
    #expect(appState.selectedRepoID == nil)
}

@MainActor
@Test func navigateToWorktree_afterInitialLoad_doesNotBuffer() async {
    let (appState, suite) = makeIsolatedAppState()
    defer { tearDown(suite) }
    appState.isInitialStateLoaded = true
    appState.archivedLookupOverride = { _ in [] }
    appState.worktrees = [:]
    let id = UUID()

    appState.navigateToWorktree(id)

    // No buffering once initial state is loaded.
    #expect(appState.pendingDeepLinkID == nil)
}

@MainActor
@Test func navigateToWorktree_beforeInitialLoad_buffersTerminalID() async {
    let appState = AppState()
    let id = UUID()
    let terminalID = UUID()
    // Default: isInitialStateLoaded == false on a fresh AppState.
    appState.worktrees = [:]

    appState.navigateToWorktree(id, terminalID: terminalID)

    #expect(appState.pendingDeepLinkID == id)
    #expect(appState.pendingDeepLinkTerminalID == terminalID)
    #expect(appState.selectedWorktreeIDs.isEmpty)
}
