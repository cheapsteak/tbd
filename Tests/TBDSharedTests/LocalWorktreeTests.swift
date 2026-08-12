import Testing
import Foundation
@testable import TBDShared

@Suite struct LocalWorktreeTests {

    private func makeWorktree(
        location: WorktreeLocation = .local, path: String = "/tmp/w"
    ) -> Worktree {
        Worktree(repoID: UUID(), name: "n", displayName: "dn", branch: "b",
                 path: path, tmuxServer: "srv", location: location)
    }

    @Test func wrapsALocalWorktree() throws {
        let wt = makeWorktree()
        let local = try #require(LocalWorktree(wt))
        #expect(local.path == "/tmp/w")
        #expect(local.tmuxServer == "srv")
    }

    @Test func refusesARemoteWorktree() {
        let wt = makeWorktree(location: .remote(provider: "agentbox", sessionID: "s-1"), path: "")
        #expect(LocalWorktree(wt) == nil)
    }

    /// A local row with an empty path is the transient `.creating`
    /// placeholder, which has no directory yet — it must not pass as local.
    @Test func refusesAnEmptyPath() {
        #expect(LocalWorktree(makeWorktree(path: "")) == nil)
    }

    @Test func forwardsOtherMembersToTheWrappedWorktree() throws {
        let wt = makeWorktree()
        let local = try #require(LocalWorktree(wt))
        #expect(local.id == wt.id)
        #expect(local.branch == "b")
        #expect(local.displayName == "dn")
        #expect(local.worktree == wt)
    }
}
