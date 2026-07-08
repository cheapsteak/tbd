import Testing
import Foundation
@testable import TBDApp

@Test func daemonCandidatePaths_withBothInputs_returnsBothCandidates() {
    let candidates = DaemonCandidateFinder.daemonCandidatePaths(
        appExecutablePath: "/Applications/TBD.app/Contents/MacOS/TBDApp",
        sourceWorktreePath: "/Users/me/tbd/worktrees/mywork"
    )
    #expect(candidates == [
        "/Applications/TBD.app/Contents/MacOS/TBDDaemon",
        "/Users/me/tbd/worktrees/mywork/.build/debug/TBDDaemon"
    ])
}

@Test func daemonCandidatePaths_withOnlyAppPath_returnsSiblingCandidate() {
    let candidates = DaemonCandidateFinder.daemonCandidatePaths(
        appExecutablePath: "/some/path/TBDApp",
        sourceWorktreePath: nil
    )
    #expect(candidates == ["/some/path/TBDDaemon"])
}

@Test func daemonCandidatePaths_withOnlyWorktreePath_returnsWorktreeCandidate() {
    let candidates = DaemonCandidateFinder.daemonCandidatePaths(
        appExecutablePath: nil,
        sourceWorktreePath: "/Users/me/tbd/worktrees/mywork"
    )
    #expect(candidates == ["/Users/me/tbd/worktrees/mywork/.build/debug/TBDDaemon"])
}

@Test func daemonCandidatePaths_withNeitherInput_returnsEmpty() {
    let candidates = DaemonCandidateFinder.daemonCandidatePaths(
        appExecutablePath: nil,
        sourceWorktreePath: nil
    )
    #expect(candidates == [])
}

@Test func daemonCandidatePaths_withEmptyWorktreePath_skipsIt() {
    let candidates = DaemonCandidateFinder.daemonCandidatePaths(
        appExecutablePath: "/Applications/TBD.app/Contents/MacOS/TBDApp",
        sourceWorktreePath: ""
    )
    #expect(candidates == ["/Applications/TBD.app/Contents/MacOS/TBDDaemon"])
}

@Test func daemonCandidatePaths_returnsSiblingFirst() {
    // Verify ordering: sibling should come before worktree
    let candidates = DaemonCandidateFinder.daemonCandidatePaths(
        appExecutablePath: "/Applications/TBD.app/Contents/MacOS/TBDApp",
        sourceWorktreePath: "/Users/me/tbd/worktrees/mywork"
    )
    #expect(candidates.count == 2)
    #expect(candidates[0].contains("Contents/MacOS/TBDDaemon"))
    #expect(candidates[1].contains(".build/debug/TBDDaemon"))
}
