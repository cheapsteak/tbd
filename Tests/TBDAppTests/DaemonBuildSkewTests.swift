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

// MARK: - Cross-source consistency

/// `DaemonBuildSkew.buildConfigurations` hand-mirrors the configurations
/// `scripts/restart.sh` can launch a daemon from. Nothing in the compiler ties
/// those two lists together, so a future third `build_config` value in the
/// script would silently reintroduce the false-positive skew warning this
/// check exists to prevent. This test is that tie: it reads the script and
/// fails if the script grows a configuration the Swift list does not know.
@Test func buildConfigurations_matchesEveryConfigurationRestartScriptCanLaunch() throws {
    // Walk up from this source file to the repo root (the dir holding `scripts/`).
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("scripts/restart.sh").path) {
        let parent = dir.deletingLastPathComponent()
        // Reached the filesystem root without finding it — skip rather than
        // fail, so a packaged/sandboxed test run doesn't red for the wrong reason.
        guard parent.path != dir.path else { return }
        dir = parent
    }
    let script = try String(contentsOf: dir.appendingPathComponent("scripts/restart.sh"), encoding: .utf8)

    // Every literal assigned to build_config, e.g. `build_config=debug` and
    // `--release) build_config=release ;;`.
    var found: Set<String> = []
    let pattern = try NSRegularExpression(pattern: #"build_config=([A-Za-z0-9_]+)"#)
    let ns = script as NSString
    for m in pattern.matches(in: script, range: NSRange(location: 0, length: ns.length)) {
        found.insert(ns.substring(with: m.range(at: 1)))
    }

    #expect(!found.isEmpty, "found no build_config assignments — did restart.sh change shape?")
    let known = Set(DaemonBuildSkew.buildConfigurations)
    let unknown = found.subtracting(known)
    #expect(
        unknown.isEmpty,
        """
        restart.sh can launch build configuration(s) \(unknown.sorted()) that \
        DaemonBuildSkew.buildConfigurations does not list \(known.sorted()). \
        A daemon launched in that configuration would be misreported as \
        cross-build skew. Add it to buildConfigurations.
        """
    )
}
