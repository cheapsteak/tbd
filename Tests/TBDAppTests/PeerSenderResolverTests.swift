import Foundation
import Testing
@testable import TBDApp
@testable import TBDShared

@Suite("PeerSenderResolver")
struct PeerSenderResolverTests {
    // MARK: Fixtures

    private func wt(_ displayName: String, id: UUID = UUID()) -> Worktree {
        Worktree(id: id, repoID: UUID(), name: displayName,
                 displayName: displayName, branch: "b",
                 path: "/tmp/\(displayName)", tmuxServer: "s")
    }

    private func verified(_ name: String, pid: Int? = 4242) -> PeerSender {
        PeerSender(name: name, from: "uds:/tmp/cc-socks/\(pid ?? 0).sock",
                   verified: true, pid: pid)
    }

    private func asserted(_ from: String) -> PeerSender {
        PeerSender(name: nil, from: from, verified: false, pid: nil)
    }

    // MARK: Tests

    @Test("verified sender with exactly one matching worktree resolves to its id")
    func exactMatchResolves() {
        let target = wt("Acme Deploy Watch")
        let worktrees = [wt("Acme Backend"), target, wt("Acme Frontend")]
        let sender = verified("Acme Deploy Watch")

        #expect(PeerSenderResolver.resolve(sender, worktrees: worktrees) == target.id)
    }

    @Test("verified sender with no matching worktree returns nil")
    func noMatchReturnsNil() {
        let worktrees = [wt("Acme Backend"), wt("Acme Frontend")]
        let sender = verified("Acme Deploy Watch")

        #expect(PeerSenderResolver.resolve(sender, worktrees: worktrees) == nil)
    }

    @Test("two worktrees sharing a display name refuse to resolve")
    func duplicateDisplayNamesReturnNil() {
        let worktrees = [wt("Acme Deploy Watch"), wt("Acme Deploy Watch"), wt("Acme Backend")]
        let sender = verified("Acme Deploy Watch")

        #expect(PeerSenderResolver.resolve(sender, worktrees: worktrees) == nil)
    }

    @Test("an asserted sender never resolves, even when from equals a display name")
    func assertedSenderNeverResolves() {
        let worktrees = [wt("acme-bot")]
        let sender = asserted("acme-bot")

        #expect(PeerSenderResolver.resolve(sender, worktrees: worktrees) == nil)
    }

    @Test("an empty worktree list returns nil for a verified sender")
    func emptyWorktreeListReturnsNil() {
        let sender = verified("Acme Deploy Watch")

        #expect(PeerSenderResolver.resolve(sender, worktrees: []) == nil)
    }
}
