import Foundation
import Testing
@testable import TBDApp
import TBDShared

// DaemonClient is a concrete actor with no test stub. These tests only verify
// the synchronous, optimistic local-state mutation in `setRepoExpanded` —
// the daemon call afterwards will fail with no daemon present and be swallowed.
// The view's render gate (worktree rows hidden when `repo.expanded == false`)
// reads directly from the same `Repo.expanded` field, so verifying the
// mutation covers both branches of the gate.

@MainActor
@Test func appState_setRepoExpanded_collapseUpdatesLocalState() async {
    let state = AppState()
    let repoID = UUID()
    state.repos = [
        Repo(id: repoID, path: "/tmp/x", displayName: "x", expanded: true)
    ]
    // Sanity: default branch — worktree rows would render.
    #expect(state.repos[0].expanded == true)

    await state.setRepoExpanded(id: repoID, expanded: false)

    // Gated branch: rows hidden.
    #expect(state.repos[0].expanded == false)
}

@MainActor
@Test func appState_setRepoExpanded_expandUpdatesLocalState() async {
    let state = AppState()
    let repoID = UUID()
    state.repos = [
        Repo(id: repoID, path: "/tmp/x", displayName: "x", expanded: false)
    ]
    #expect(state.repos[0].expanded == false)

    await state.setRepoExpanded(id: repoID, expanded: true)

    // Ungated branch: rows render again.
    #expect(state.repos[0].expanded == true)
}

@Test func repo_defaultIsExpanded() {
    let repo = Repo(path: "/tmp/x", displayName: "x")
    #expect(repo.expanded == true)
}

@Test func repo_decodesMissingExpandedAsTrue() throws {
    // Old JSON shape (no `expanded` field) must decode as expanded so
    // existing daemon installs don't suddenly collapse every repo.
    let json = """
    {
      "id": "\(UUID().uuidString)",
      "path": "/tmp/old",
      "displayName": "old",
      "defaultBranch": "main",
      "createdAt": 0,
      "status": "ok",
      "hidden": false
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let repo = try decoder.decode(Repo.self, from: json)
    #expect(repo.expanded == true)
}
