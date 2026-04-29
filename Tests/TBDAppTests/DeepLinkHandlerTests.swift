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
    let url = DeepLink.makeOpenWorktreeURL(UUID())

    DeepLinkHandler.handle(url, appState: appState)

    #expect(appState.selectedWorktreeIDs.isEmpty)
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
