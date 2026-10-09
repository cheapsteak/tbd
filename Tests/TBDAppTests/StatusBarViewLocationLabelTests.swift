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

// MARK: - Remote rows: selection and the location/branch label

private func remoteRow(sessionID: String = "s-1") -> Worktree {
    let location = WorktreeLocation.remote(provider: "agentbox", sessionID: sessionID)
    return Worktree(
        id: UUID(),
        repoID: UUID(),
        name: "r",
        displayName: "R",
        branch: "main",
        path: location.storagePath ?? "",
        status: .active,
        tmuxServer: "",
        location: location
    )
}

private func session(
    _ id: String = "s-1",
    provider: String = "agentbox",
    meta: [String: String]?,
    gone: Bool = false
) -> RemoteSessionInfo {
    RemoteSessionInfo(
        provider: provider,
        payload: RemoteSessionPayload(id: id, state: .running, meta: meta),
        gone: gone,
        dismissed: false,
        lastSeen: Date()
    )
}

private func label(location: String?, branch: String?) -> StatusBarView.RemoteStatusLabel {
    StatusBarView.RemoteStatusLabel(location: location, branch: branch)
}

@Test func remoteLabel_locationAndBranchPresent() {
    let result = StatusBarView.remoteStatusLabel(provider: "agentbox", sessionID: "s-1", sessions: [
        session(meta: ["location": "dev@devbox:/srv/acme-api", "branch": "claude/fix-x"])])
    #expect(result == label(location: "dev@devbox:/srv/acme-api", branch: "claude/fix-x"))
}

/// Verbatim: a location under what would be a local home is not abbreviated.
@Test func remoteLabel_locationIsVerbatim() {
    let result = StatusBarView.remoteStatusLabel(provider: "agentbox", sessionID: "s-1", sessions: [
        session(meta: ["location": "devbox:/Users/me/wt"])])
    #expect(result.location == "devbox:/Users/me/wt")
}

@Test func remoteLabel_absentKeysHideOnlyTheirOwnElement() {
    #expect(StatusBarView.remoteStatusLabel(provider: "agentbox", sessionID: "s-1",
        sessions: [session(meta: ["branch": "claude/fix-x"])]) == label(location: nil, branch: "claude/fix-x"))
    #expect(StatusBarView.remoteStatusLabel(provider: "agentbox", sessionID: "s-1",
        sessions: [session(meta: ["location": "devbox:/srv/a"])]) == label(location: "devbox:/srv/a", branch: nil))
    #expect(StatusBarView.remoteStatusLabel(provider: "agentbox", sessionID: "s-1",
        sessions: [session(meta: nil)]) == label(location: nil, branch: nil))
}

@Test func remoteLabel_malformedKeysHideOnlyTheirOwnElement() {
    let result = StatusBarView.remoteStatusLabel(provider: "agentbox", sessionID: "s-1",
        sessions: [session(meta: ["location": "devbox:relative", "branch": "-rf"])])
    #expect(result == label(location: nil, branch: nil))
    let mixed = StatusBarView.remoteStatusLabel(provider: "agentbox", sessionID: "s-1",
        sessions: [session(meta: ["location": "ssh://devbox/srv/a", "branch": "claude/ok"])])
    #expect(mixed == label(location: nil, branch: "claude/ok"))
}

@Test func remoteLabel_neverFallsBackToProviderOrSessionID() {
    let result = StatusBarView.remoteStatusLabel(provider: "agentbox", sessionID: "s-1", sessions: [])
    #expect(result == label(location: nil, branch: nil))
}

@Test func remoteLabel_staleMirrorShowsLastKnown() {
    let result = StatusBarView.remoteStatusLabel(provider: "agentbox", sessionID: "s-1",
        sessions: [session(meta: ["location": "devbox:/srv/a", "branch": "b"], gone: true)])
    #expect(result == label(location: "devbox:/srv/a", branch: "b"))
}

@Test func remoteLabel_readsItsOwnSessionOnly() {
    let result = StatusBarView.remoteStatusLabel(provider: "agentbox", sessionID: "s-1", sessions: [
        session("s-2", meta: ["location": "other:/x"]),
        session("s-1", provider: "otherbox", meta: ["location": "wrong:/z"]),
        session("s-1", meta: ["location": "mine:/y"])])
    #expect(result.location == "mine:/y")
}

@Test func selection_remoteRowIsRemote_evenWithNoKeys() {
    let row = remoteRow()
    guard case .remote(let id, let result)? = StatusBarView.statusBarSelection(row, sessions: []) else {
        Issue.record("expected .remote"); return
    }
    // Chips still render from effectivePRBindings(row.id).
    #expect(id == row.id)
    #expect(result == label(location: nil, branch: nil))
}

@Test func selection_remoteRowReadsItsSession() {
    let row = remoteRow(sessionID: "s-9")
    let sessions = [session("s-9", meta: ["location": "devbox:/srv/a", "branch": "claude/live"])]
    let selection = StatusBarView.statusBarSelection(row, sessions: sessions)
    #expect(selection == .remote(worktreeID: row.id,
                                 label: label(location: "devbox:/srv/a", branch: "claude/live")))
    #expect(selection?.worktreeID == row.id)
}

@Test func selection_localRowUnchanged() {
    let local = worktree(branch: "feature/x", path: "/Users/me/wt")
    guard case .local(let lw)? = StatusBarView.statusBarSelection(local, sessions: []) else {
        Issue.record("expected .local"); return
    }
    #expect(lw.worktree.id == local.id)
    #expect(StatusBarView.statusBarSelection(local, sessions: [])?.worktreeID == local.id)
    #expect(StatusBarView.locationLabel(lw, home: "/Users/me")?.displayPath == "~/wt")
}

@Test func selection_localRowWithoutPathIsNil() {
    #expect(StatusBarView.statusBarSelection(worktree(branch: "x", path: ""), sessions: []) == nil)
}

@Test func selection_landedRowRendersAsLocal() {
    var landed = worktree(branch: "claude/landed", path: "/Users/me/wt/landed")
    landed.origin = WorktreeOrigin(provider: "agentbox", sessionID: "s-1")
    let sessions = [session(meta: ["location": "devbox:/srv/a", "branch": "claude/other"])]
    guard case .local(let lw)? = StatusBarView.statusBarSelection(landed, sessions: sessions) else {
        Issue.record("expected .local"); return
    }
    #expect(StatusBarView.locationLabel(lw, home: "/Users/me")?.branch == "claude/landed")
}

@Test func selection_nilWorktreeIsNil() {
    #expect(StatusBarView.statusBarSelection(nil, sessions: []) == nil)
}
