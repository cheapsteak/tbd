import Foundation
import TBDShared
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

// MARK: - Build stamps

/// The update clone and the release tree its `.build/release` links to while a
/// downloaded build is installed. Fabricated, like every path above.
private let updateClone = "/Users/me/tbd/updates/src"
private let prebuiltDaemon = "/Users/me/tbd/updates/prebuilt/1111111111111111111111111111111111111111/TBDDaemon"

private func stamp(
    commit: String = "1111111111111111111111111111111111111111",
    sourceWorktree: String? = updateClone,
    dirty: Bool = false,
    origin: BuildIdentityOrigin = .stamp
) -> BuildIdentity {
    BuildIdentity(
        commit: commit, shortCommit: String(commit.prefix(8)), branch: "HEAD",
        builtAt: "2026-01-01T00:00:00Z", sourceWorktree: sourceWorktree,
        dirty: dirty, origin: origin)
}

/// What the path check sees while `scripts/update.sh` compiles `TBDApp` for a
/// release install: the clone's `.build/release` link is handed back to
/// SwiftPM, so `<clone>/.build/release/TBDDaemon` no longer resolves to the
/// prebuilt binary the daemon runs from. The identity resolver models that by
/// leaving every path as spelled.
private func updateWindowMessage(app: BuildIdentity?, daemon: BuildIdentity?) -> String? {
    DaemonBuildSkew.warningMessage(
        daemonExecutablePath: prebuiltDaemon,
        appSiblingDaemonPath: "/Applications/TBD.app/Contents/MacOS/TBDDaemon",
        sourceWorktreePath: updateClone,
        appIdentity: app,
        daemonIdentity: daemon,
        resolvePath: identity
    )
}

@Test func warningMessage_updateWindowWithoutStamps_warns() {
    // The false positive this guards against, reproduced: with no stamps to
    // consult, the path check alone calls a matched pair skew.
    #expect(updateWindowMessage(app: nil, daemon: nil)?.contains(prebuiltDaemon) == true)
}

@Test func warningMessage_updateWindowWithMatchingStamps_returnsNil() {
    #expect(updateWindowMessage(app: stamp(), daemon: stamp()) == nil)
}

@Test func warningMessage_stampsFromDifferentWorktrees_stillWarns() {
    let message = updateWindowMessage(
        app: stamp(), daemon: stamp(sourceWorktree: "/Users/me/proj/tbd/.claude/worktrees/other-wt"))
    #expect(message?.contains(prebuiltDaemon) == true)
}

@Test func warningMessage_stampsAtDifferentCommits_stillWarns() {
    let message = updateWindowMessage(
        app: stamp(), daemon: stamp(commit: "2222222222222222222222222222222222222222"))
    #expect(message?.contains(prebuiltDaemon) == true)
}

@Test func warningMessage_dirtyStamp_stillWarns() {
    // Two dirty builds of one commit can hold different code.
    #expect(updateWindowMessage(app: stamp(dirty: true), daemon: stamp(dirty: true)) != nil)
    #expect(updateWindowMessage(app: stamp(), daemon: stamp(dirty: true)) != nil)
}

@Test func warningMessage_identityFromWorktreeHead_stillWarns() {
    // A HEAD read after the fact may be stale, so it proves nothing.
    #expect(updateWindowMessage(app: stamp(), daemon: stamp(origin: .worktreeHead)) != nil)
    #expect(updateWindowMessage(app: stamp(origin: .worktreeHead), daemon: stamp()) != nil)
}

@Test func warningMessage_oneSideUnstamped_stillWarns() {
    #expect(updateWindowMessage(app: stamp(), daemon: nil) != nil)
    #expect(updateWindowMessage(app: nil, daemon: stamp()) != nil)
    #expect(updateWindowMessage(app: stamp(sourceWorktree: nil), daemon: stamp(sourceWorktree: nil)) != nil)
}

@Test func warningMessage_matchingStampsDoNotSilenceAMissingDaemonPath() {
    // An old daemon without `executablePath` stays quiet for its own reason;
    // the stamp check never turns that into a warning either way.
    let message = DaemonBuildSkew.warningMessage(
        daemonExecutablePath: nil,
        appSiblingDaemonPath: nil,
        sourceWorktreePath: updateClone,
        appIdentity: stamp(),
        daemonIdentity: stamp(commit: "2222222222222222222222222222222222222222"),
        resolvePath: identity
    )
    #expect(message == nil)
}

@Test func isSameStampedBuild_resolvesWorktreeSpellings() {
    let resolve: (String) -> String = { path in
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
    #expect(DaemonBuildSkew.isSameStampedBuild(
        app: stamp(sourceWorktree: "/tmp/wt"),
        daemon: stamp(sourceWorktree: "/private/tmp/wt"),
        resolvePath: resolve))
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
