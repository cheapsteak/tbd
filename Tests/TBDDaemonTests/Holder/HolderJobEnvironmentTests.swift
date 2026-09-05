import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// What a holder-transport job inherits from the daemon, and what it must not.
///
/// The daemon is usually restarted from inside a Claude Code session, so its
/// environment carries that session's exported identity. A job that inherits it
/// is read by Claude Code as a nested child — no row in the cross-session peer
/// registry, and session persistence off, so no transcript either. The tmux
/// transport escapes this because Claude Code can ask the tmux server whether
/// the marker is ambient; the holder transport has no server to ask.
///
/// The composed environment is asserted as a **whole dictionary**, not searched
/// for the absence of the names that leaked. Pinning the composition means an
/// over-eager scrub (dropping `PATH`, `SHELL`, or a user's own Claude Code
/// configuration) fails here too, not only an under-eager one.
@Suite("Holder job environment")
struct HolderJobEnvironmentTests {
    /// Everything a job legitimately inherits: the machine's own environment,
    /// plus Claude Code *configuration* a user may deliberately set in their
    /// login environment. None of this describes the enclosing session.
    private static let kept: [String: String] = [
        "PATH": "/usr/bin:/bin",
        "HOME": "/Users/example",
        "SHELL": "/bin/zsh",
        "TERM": "xterm-256color",
        "LANG": "en_US.UTF-8",
        "CLAUDE_CONFIG_DIR": "/tmp/example-profile/claude",
        "CLAUDE_CODE_USE_BEDROCK": "1",
    ]

    /// Every marker, given a value distinctive enough that a failure message
    /// says which one survived.
    private static let markers: [String: String] = Dictionary(
        uniqueKeysWithValues: HolderJobEnvironment.enclosingSessionMarkers.map { name in
            (name, "enclosing-session-value-for-\(name)")
        })

    private static var daemonEnvironment: [String: String] {
        kept.merging(markers) { _, marker in marker }
    }

    private static func launch(sensitiveEnv: [String: String]) -> HolderLaunchRequest {
        WorktreeLifecycle.holderLaunch(
            shellCommand: "claude --flag",
            env: ["TBD_TERMINAL_ID": "t1"],
            sensitiveEnv: sensitiveEnv,
            workingDirectory: "/tmp/wd",
            cols: 120,
            rows: 40,
            environment: daemonEnvironment)
    }

    @Test func theJobDoesNotInheritTheEnclosingSessionsMarkers() {
        let request = Self.launch(sensitiveEnv: [:])

        #expect(request.environment == Self.kept)

        // The shell invocation is unchanged in shape — `SHELL` is read from the
        // same environment, so an over-broad scrub would show up here as a
        // different interpreter rather than as a missing variable.
        #expect(request.executable == "/bin/zsh")
        #expect(request.arguments.last?.contains("claude --flag") == true)
    }

    /// The scrub applies to the inherited base only. Whatever the spawn itself
    /// decided is merged on top and wins, so a deliberate override reaches the
    /// job even under one of the scrubbed names.
    @Test func aValueTheSpawnDecidedSurvivesEvenUnderAMarkersName() {
        let sensitiveEnv = [
            "CLAUDE_CODE_ENTRYPOINT": "deliberate-override",
            "EXAMPLE_TOKEN": "placeholder",
        ]
        let request = Self.launch(sensitiveEnv: sensitiveEnv)

        #expect(request.environment == Self.kept.merging(sensitiveEnv) { _, decided in decided })
    }

    @Test func anUnmarkedEnvironmentPassesThroughUnchanged() {
        #expect(HolderJobEnvironment.inheriting(Self.kept) == Self.kept)
    }

    /// Pinned by name so adding or removing one is a visible, reviewed change
    /// rather than a quiet widening of what a job loses.
    @Test func theMarkerSetIsExactlyTheEnclosingSessionsIdentity() {
        #expect(HolderJobEnvironment.enclosingSessionMarkers == [
            "CLAUDECODE",
            "CLAUDE_CODE_CHILD_SESSION",
            "CLAUDE_CODE_ENTRYPOINT",
            "CLAUDE_CODE_SESSION_ID",
            "CLAUDE_CODE_MESSAGING_SOCKET",
            "CLAUDE_CODE_MESSAGING_TOKEN",
            "CLAUDE_CODE_BRIDGE_SESSION_ID",
            "CLAUDE_CODE_EXECPATH",
            "CLAUDE_PID",
            "TMUX",
            "TMUX_PANE",
        ])
    }
}
