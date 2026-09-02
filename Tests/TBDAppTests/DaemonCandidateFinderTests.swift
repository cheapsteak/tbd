import Testing
import Foundation
@testable import TBDApp

// The worktree candidates follow this app's OWN build configuration first, so
// these tests derive the expected order rather than hardcoding "debug" — the
// suite compiles in whichever configuration the run uses, and hardcoding would
// make it pass in one and fail in the other for no real reason.
private let configOrder = DaemonCandidateFinder.buildConfigurationSearchOrder
private func worktreeCandidates(_ worktree: String) -> [String] {
    configOrder.map { worktree + "/.build/\($0)/TBDDaemon" }
}

@Test func daemonCandidatePaths_withBothInputs_returnsSiblingThenEachConfiguration() {
    let candidates = DaemonCandidateFinder.daemonCandidatePaths(
        appExecutablePath: "/Applications/TBD.app/Contents/MacOS/TBDApp",
        sourceWorktreePath: "/Users/me/tbd/worktrees/mywork"
    )
    #expect(candidates == ["/Applications/TBD.app/Contents/MacOS/TBDDaemon"]
        + worktreeCandidates("/Users/me/tbd/worktrees/mywork"))
}

@Test func daemonCandidatePaths_withOnlyAppPath_returnsSiblingCandidate() {
    let candidates = DaemonCandidateFinder.daemonCandidatePaths(
        appExecutablePath: "/some/path/TBDApp",
        sourceWorktreePath: nil
    )
    #expect(candidates == ["/some/path/TBDDaemon"])
}

@Test func daemonCandidatePaths_withOnlyWorktreePath_returnsWorktreeCandidates() {
    let candidates = DaemonCandidateFinder.daemonCandidatePaths(
        appExecutablePath: nil,
        sourceWorktreePath: "/Users/me/tbd/worktrees/mywork"
    )
    #expect(candidates == worktreeCandidates("/Users/me/tbd/worktrees/mywork"))
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
    let candidates = DaemonCandidateFinder.daemonCandidatePaths(
        appExecutablePath: "/Applications/TBD.app/Contents/MacOS/TBDApp",
        sourceWorktreePath: "/Users/me/tbd/worktrees/mywork"
    )
    #expect(candidates.first?.contains("Contents/MacOS/TBDDaemon") == true)
}

@Test func daemonCandidatePaths_offersBothConfigurations() {
    // The regression this guards: the list once named only `debug`, so a
    // release app that auto-spawned its daemon (what happens after a reboot,
    // with no daemon running) paired a release app with a DEBUG daemon.
    let candidates = DaemonCandidateFinder.daemonCandidatePaths(
        appExecutablePath: nil,
        sourceWorktreePath: "/w"
    )
    #expect(candidates.contains("/w/.build/release/TBDDaemon"))
    #expect(candidates.contains("/w/.build/debug/TBDDaemon"))
}

@Test func buildConfigurationSearchOrder_prefersThisAppsOwnConfiguration() {
    // A test binary is compiled `-c debug`, so DEBUG is defined here and the
    // matching-first rule must put "debug" ahead of "release". In a release
    // build the same rule yields the reverse; asserting the invariant through
    // `#if DEBUG` keeps the test honest in both.
    #if DEBUG
    #expect(configOrder == ["debug", "release"])
    #else
    #expect(configOrder == ["release", "debug"])
    #endif
    #expect(Set(configOrder) == ["debug", "release"])
}
