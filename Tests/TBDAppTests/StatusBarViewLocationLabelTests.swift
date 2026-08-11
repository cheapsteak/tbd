import Testing
import Foundation
import TBDShared
@testable import TBDApp

// Tier 1: pure formatting helpers for the bottom-left status-bar cluster.

private func worktree(branch: String, path: String) -> Worktree {
    Worktree(
        id: UUID(),
        repoID: UUID(),
        name: "wt",
        displayName: "WT",
        branch: branch,
        path: path,
        status: .active,
        tmuxServer: "test-server"
    )
}

/// The helper takes the proven-local wrapper, so the cases below build one.
private func localWorktree(branch: String, path: String) -> LocalWorktree? {
    LocalWorktree(worktree(branch: branch, path: path))
}

@Test func locationLabel_abbreviatesPathAndKeepsFullValueForCopying() {
    let label = StatusBarView.locationLabel(
        localWorktree(branch: "feature/x", path: "/Users/me/tbd/worktrees/acme/wt"),
        home: "/Users/me"
    )
    #expect(label?.displayPath == "~/tbd/worktrees/acme/wt")
    #expect(label?.path == "/Users/me/tbd/worktrees/acme/wt")
    #expect(label?.branch == "feature/x")
}

@Test func locationLabel_nilWorktree_returnsNil() {
    #expect(StatusBarView.locationLabel(nil, home: "/Users/me") == nil)
}

/// The empty-path rule moved into `LocalWorktree`: the label helper no longer
/// spells it out, so this asserts it at the boundary that now owns it. Without
/// it, a worktree with no checkout would reach the status bar as a blank path.
@Test func locationLabel_emptyPathWorktree_doesNotConvertToLocal() {
    #expect(localWorktree(branch: "main", path: "") == nil)
}

@Test func locationLabel_blankBranch_dropsBranchSegment() {
    let label = StatusBarView.locationLabel(
        localWorktree(branch: "   ", path: "/Users/me/scratch"),
        home: "/Users/me"
    )
    #expect(label?.branch == nil)
    #expect(label?.displayPath == "~/scratch")
}

@Test func abbreviateWithTilde_onlyMatchesWholeComponents() {
    // A sibling directory sharing the home prefix must not be abbreviated.
    #expect(StatusBarView.abbreviateWithTilde("/Users/meadow/x", home: "/Users/me") == "/Users/meadow/x")
    #expect(StatusBarView.abbreviateWithTilde("/Users/me", home: "/Users/me") == "~")
    #expect(StatusBarView.abbreviateWithTilde("/Users/me/a", home: "/Users/me/") == "~/a")
    #expect(StatusBarView.abbreviateWithTilde("/opt/other", home: "/Users/me") == "/opt/other")
    #expect(StatusBarView.abbreviateWithTilde("/Users/me/a", home: "") == "/Users/me/a")
}
