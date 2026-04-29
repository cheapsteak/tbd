import Testing
import Foundation
import TBDShared
@testable import TBDApp

@MainActor
@Test func handle_knownActiveUUID_selectsWorktree() async {
    let appState = AppState()
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
    let appState = AppState()
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
    let appState = AppState()
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
    let appState = AppState()
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
