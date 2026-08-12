import Foundation
import Testing
@testable import TBDApp

// Identity resolver: paths in these tests are fabricated, so the default
// (symlink-resolving) resolver would be a no-op anyway; passing an explicit
// identity keeps the tests hermetic against filesystem state.
private let identity: @Sendable (String) -> String = { $0 }

@Test func warningMessage_daemonMatchesSourceWorktreeBuild_returnsNil() {
    // Normal restart.sh topology: app runs from /Applications, daemon runs
    // from the SAME worktree's .build/debug.
    let message = DaemonBuildSkew.warningMessage(
        daemonExecutablePath: "/Users/me/proj/tbd/.build/debug/TBDDaemon",
        appSiblingDaemonPath: "/Applications/TBD.app/Contents/MacOS/TBDDaemon",
        sourceWorktreePath: "/Users/me/proj/tbd",
        resolvePath: identity
    )
    #expect(message == nil)
}

@Test func warningMessage_daemonMatchesSourceWorktreeReleaseBuild_returnsNil() {
    // `scripts/restart.sh --release` topology: same worktree, optimized
    // build. Only the .build subdirectory differs from the debug case, so
    // this is a deliberate configuration choice and NOT cross-build skew.
    let message = DaemonBuildSkew.warningMessage(
        daemonExecutablePath: "/Users/me/proj/tbd/.build/release/TBDDaemon",
        appSiblingDaemonPath: "/Applications/TBD.app/Contents/MacOS/TBDDaemon",
        sourceWorktreePath: "/Users/me/proj/tbd",
        resolvePath: identity
    )
    #expect(message == nil)
}

@Test func warningMessage_releaseDaemonFromOtherWorktree_stillWarns() {
    // Widening to release must not blunt the real signal: a release daemon
    // from a DIFFERENT worktree is still skew.
    let otherBuild = "/Users/me/proj/tbd/.claude/worktrees/other-wt/.build/release/TBDDaemon"
    let message = DaemonBuildSkew.warningMessage(
        daemonExecutablePath: otherBuild,
        appSiblingDaemonPath: "/Applications/TBD.app/Contents/MacOS/TBDDaemon",
        sourceWorktreePath: "/Users/me/proj/tbd",
        resolvePath: identity
    )
    #expect(message?.contains(otherBuild) == true)
}

@Test func warningMessage_daemonMatchesAppSibling_returnsNil() {
    // App-spawned daemon: TBDDaemon sits next to the app executable.
    let message = DaemonBuildSkew.warningMessage(
        daemonExecutablePath: "/Users/me/proj/tbd/.build/debug/TBDDaemon",
        appSiblingDaemonPath: "/Users/me/proj/tbd/.build/debug/TBDDaemon",
        sourceWorktreePath: nil,
        resolvePath: identity
    )
    #expect(message == nil)
}

@Test func warningMessage_daemonFromOtherWorktree_returnsWarningNamingDaemonPath() {
    let otherBuild = "/Users/me/proj/tbd/.claude/worktrees/other-wt/.build/debug/TBDDaemon"
    let message = DaemonBuildSkew.warningMessage(
        daemonExecutablePath: otherBuild,
        appSiblingDaemonPath: "/Applications/TBD.app/Contents/MacOS/TBDDaemon",
        sourceWorktreePath: "/Users/me/proj/tbd",
        resolvePath: identity
    )
    let unwrapped = try? #require(message)
    #expect(unwrapped?.contains(otherBuild) == true)
    #expect(unwrapped?.contains("scripts/restart.sh") == true)
}

@Test func warningMessage_oldDaemonWithoutField_returnsNil() {
    // Pre-handshake daemons omit executablePath; decode-compatible clients
    // must stay quiet rather than false-positive.
    let message = DaemonBuildSkew.warningMessage(
        daemonExecutablePath: nil,
        appSiblingDaemonPath: "/Applications/TBD.app/Contents/MacOS/TBDDaemon",
        sourceWorktreePath: "/Users/me/proj/tbd",
        resolvePath: identity
    )
    #expect(message == nil)
}

@Test func warningMessage_emptyDaemonPath_returnsNil() {
    let message = DaemonBuildSkew.warningMessage(
        daemonExecutablePath: "",
        appSiblingDaemonPath: "/Applications/TBD.app/Contents/MacOS/TBDDaemon",
        sourceWorktreePath: "/Users/me/proj/tbd",
        resolvePath: identity
    )
    #expect(message == nil)
}

@Test func warningMessage_noExpectedCandidates_returnsNil() {
    // App identity unknown (no sibling, no source worktree) — can't judge.
    let message = DaemonBuildSkew.warningMessage(
        daemonExecutablePath: "/Users/me/proj/tbd/.build/debug/TBDDaemon",
        appSiblingDaemonPath: nil,
        sourceWorktreePath: nil,
        resolvePath: identity
    )
    #expect(message == nil)
}

@Test func warningMessage_resolverUnifiesEquivalentSpellings() {
    // The resolver seam is what maps /tmp-style symlinked spellings onto one
    // canonical form; a resolver that unifies them must suppress the warning.
    let message = DaemonBuildSkew.warningMessage(
        daemonExecutablePath: "/private/tmp/wt/.build/debug/TBDDaemon",
        appSiblingDaemonPath: nil,
        sourceWorktreePath: "/tmp/wt",
        resolvePath: { path in
            path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
        }
    )
    #expect(message == nil)
}

@Test func defaultResolvePath_standardizesDotComponents() {
    let resolved = DaemonBuildSkew.defaultResolvePath("/Users/me/proj/tbd/./.build/debug/TBDDaemon")
    #expect(resolved == "/Users/me/proj/tbd/.build/debug/TBDDaemon")
}
