import Testing
@testable import TBDDaemonLib

/// The name a repo's worktree rows carry in `tmuxServer`. The leftover-server
/// probe finds a tmux row's server by it, so it must come out the same in
/// every daemon process, for every path, forever.
@Suite("tmux server name")
struct TmuxServerNameTests {
    /// A fixed value: a change to the hash would point every existing tmux
    /// row's probe at a socket its server never had.
    @Test func itIsStableForAPath() {
        #expect(TmuxServerName.forRepoPath("/tmp/repo") == "tbd-322a23ca")
    }

    @Test func itIsAtMostEightLowercaseHexDigitsAfterThePrefix() {
        let name = TmuxServerName.forRepoPath("/Users/acme/src/acme-prod")
        #expect(name.hasPrefix("tbd-"))
        let hex = name.dropFirst("tbd-".count)
        #expect(hex.count <= 8)
        #expect(hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test func differentPathsGiveDifferentNames() {
        #expect(TmuxServerName.forRepoPath("/tmp/acme-a") != TmuxServerName.forRepoPath("/tmp/acme-b"))
    }
}
