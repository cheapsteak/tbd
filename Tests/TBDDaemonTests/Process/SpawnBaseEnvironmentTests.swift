import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// What a process the daemon spawns — a holder job, or the tmux server — starts
/// from, and what it must not.
///
/// The daemon is usually restarted from inside a Claude Code session, so its
/// environment carries that session's exported identity. A job that inherits it
/// is read by Claude Code as a nested child — no row in the cross-session peer
/// registry, and session persistence off, so no transcript either. Claude Code
/// treats a marker found in the tmux server's global environment as ambient, so
/// the tmux path never showed that symptom; TBD's own guards have no such probe,
/// which is why the scrub is applied to both transports rather than one.
///
/// TBD's own per-terminal exports carry the same hazard onto TBD's own
/// surfaces: an inherited `TBD_TERMINAL_INCARNATION_ID` names the launcher's
/// process lifetime, so the guard in `TerminalStore.applySessionStart` rejects
/// the job's hooks and the session gets no id, no transcript path and no
/// activity. TERM is the one name that is *pinned* rather than passed through
/// or dropped — the tmux path gives every pane `xterm-256color`, and the holder
/// path must hand the job the same terminal type rather than whichever emulator
/// the daemon happened to be restarted from. `CLAUDE_CONFIG_DIR` is the one name
/// whose *value* decides: a directory under this installation's profiles root is
/// something only TBD writes, so it is per-spawn identity, while any other value
/// is the user's own configuration and survives.
///
/// The composed environment is asserted as a **whole dictionary**, not searched
/// for the absence of the names that leaked. Pinning the composition means an
/// over-eager scrub (dropping `PATH`, `SHELL`, or a user's own Claude Code
/// configuration) fails here too, not only an under-eager one.
@Suite("Spawn base environment")
struct SpawnBaseEnvironmentTests {
    /// Everything a job legitimately inherits: the machine's own environment,
    /// plus Claude Code and TBD *configuration* a user or installation may
    /// deliberately set. None of this describes the enclosing session.
    private static let kept: [String: String] = [
        "PATH": "/usr/bin:/bin",
        "HOME": "/Users/example",
        "SHELL": "/bin/zsh",
        "LANG": "en_US.UTF-8",
        // A config dir the user set themselves: outside TBD's profiles root, so
        // every whole-dictionary assertion below doubles as the case that a
        // user's own `CLAUDE_CONFIG_DIR` survives the scrub.
        "CLAUDE_CONFIG_DIR": "/tmp/example-profile/claude",
        "CLAUDE_CODE_USE_BEDROCK": "1",
        "TBD_HOME": "/tmp/example-tbd-home",
    ]

    /// Not inherited and not dropped: handed to the job outright, matching what
    /// the tmux server's `default-terminal` gives every pane.
    private static let pinned: [String: String] = ["TERM": "xterm-256color"]

    /// Every marker, given a value distinctive enough that a failure message
    /// says which one survived.
    private static let markers: [String: String] = Dictionary(
        uniqueKeysWithValues: SpawnBaseEnvironment.enclosingSessionMarkers.map { name in
            (name, "enclosing-session-value-for-\(name)")
        })

    /// The markers, plus a TERM naming some other terminal emulator — the value
    /// a daemon restarted outside a tmux pane would otherwise pass on.
    private static var daemonEnvironment: [String: String] {
        kept
            .merging(markers) { _, marker in marker }
            .merging(["TERM": "xterm-ghostty"]) { _, launcherTerm in launcherTerm }
    }

    private static func launch(
        sensitiveEnv: [String: String],
        environment: [String: String]? = nil
    ) -> HolderLaunchRequest {
        WorktreeLifecycle.holderLaunch(
            shellCommand: "claude --flag",
            env: ["TBD_TERMINAL_ID": "t1"],
            sensitiveEnv: sensitiveEnv,
            workingDirectory: "/tmp/wd",
            cols: 120,
            rows: 40,
            environment: environment ?? daemonEnvironment)
    }

    @Test func theJobDoesNotInheritTheEnclosingSessionsMarkers() {
        let request = Self.launch(sensitiveEnv: [:])

        #expect(request.environment == Self.kept.merging(Self.pinned) { _, pin in pin })

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

        let expected = Self.kept
            .merging(Self.pinned) { _, pin in pin }
            .merging(sensitiveEnv) { _, decided in decided }
        #expect(request.environment == expected)
    }

    @Test func anUnmarkedEnvironmentPassesThroughUnchanged() {
        let base = Self.kept.merging(Self.pinned) { _, pin in pin }
        #expect(SpawnBaseEnvironment.inheriting(base) == base)
    }

    /// The union of the four groups, pinned by name so adding or removing one
    /// is a visible, reviewed change rather than a quiet widening of what a job
    /// loses. `theGroupsPartitionTheSet` below ties the groups back to it, so a
    /// name cannot move between them and go unnoticed here.
    @Test func theMarkerSetIsExactlyTheEnclosingSessionsIdentity() {
        #expect(SpawnBaseEnvironment.enclosingSessionMarkers == [
            "CLAUDECODE",
            "CLAUDE_CODE_CHILD_SESSION",
            "CLAUDE_CODE_ENTRYPOINT",
            "CLAUDE_CODE_SESSION_ID",
            "CLAUDE_CODE_MESSAGING_SOCKET",
            "CLAUDE_CODE_MESSAGING_TOKEN",
            "CLAUDE_CODE_BRIDGE_SESSION_ID",
            "CLAUDE_CODE_EXECPATH",
            "CLAUDE_PID",
            "AI_AGENT",
            "CLAUDE_EFFORT",
            "TRACEPARENT",
            "TBD_TERMINAL_ID",
            "TBD_TERMINAL_INCARNATION_ID",
            "TBD_WORKTREE_ID",
            "TBD_CLI_PATH",
            "TBD_EVENT",
            "TBD_WORKTREE_NAME",
            "TBD_WORKTREE_PATH",
            "TBD_REPO_PATH",
            "TBD_BRANCH",
            "TBD_PROMPT_CONTEXT",
            "TBD_PROMPT_INSTRUCTIONS",
            "TBD_PROMPT_RENAME",
            "TBD_PROMPT_SCRATCH",
            "TBD_HANDOVER_FROM_PID",
            "CODEX_CI",
            "CODEX_THREAD_ID",
            "TMUX",
            "TMUX_PANE",
        ])
    }

    /// The union is what every existing caller applies, so the four groups have
    /// to account for it exactly: a name that fell out of a group while the
    /// pinned list above stayed green would be a name nothing scrubs.
    @Test func theGroupsPartitionTheSet() {
        let groups: [Set<String>] = [
            SpawnBaseEnvironment.claudeCodeSessionMarkers,
            SpawnBaseEnvironment.tbdProcessMarkers,
            SpawnBaseEnvironment.codexSessionMarkers,
            SpawnBaseEnvironment.tmuxPaneMarkers,
        ]

        for (index, group) in groups.enumerated() {
            for other in groups[(index + 1)...] {
                #expect(group.isDisjoint(with: other))
            }
        }
        #expect(groups.reduce(into: Set<String>()) { $0.formUnion($1) }
            == SpawnBaseEnvironment.enclosingSessionMarkers)
    }

    /// What an *existing* tmux server may have stripped in place is a strict
    /// subset. Claude Code reads a marker as ambient only while the server's
    /// global environment carries it, so removing the global copy would make a
    /// `claude` started later in a pane that predates the repair — a pane
    /// holding its own copy — read itself as a nested child. `TMUX` and
    /// `TMUX_PANE` are the server's own.
    @Test func serverRepairSparesClaudeCodesMarkersAndTheTmuxPanes() {
        #expect(
            SpawnBaseEnvironment.serverRepairableMarkers
                == SpawnBaseEnvironment.tbdProcessMarkers
                    .union(SpawnBaseEnvironment.codexSessionMarkers))
        #expect(SpawnBaseEnvironment.serverRepairableMarkers
            .isDisjoint(with: SpawnBaseEnvironment.claudeCodeSessionMarkers))
        #expect(SpawnBaseEnvironment.serverRepairableMarkers
            .isDisjoint(with: SpawnBaseEnvironment.tmuxPaneMarkers))
    }

    /// An empty value is not a config dir. Every reader of the name in this
    /// tree guards on `!isEmpty` and falls back as though it were unset, so a
    /// job is better served by the name being absent than by an empty string it
    /// would have to guard for itself — and nothing downstream then hands the
    /// empty string to `URL(fileURLWithPath:)`.
    @Test func anEmptyConfigDirIsDroppedRatherThanHandedToTheJob() {
        var base = Self.kept
        base["CLAUDE_CONFIG_DIR"] = ""

        let inherited = SpawnBaseEnvironment.inheriting(base)
        let expected = Self.kept
            .merging(Self.pinned) { _, pin in pin }
            .filter { $0.key != "CLAUDE_CONFIG_DIR" }

        #expect(inherited["CLAUDE_CONFIG_DIR"] == nil)
        #expect(inherited == expected)
    }

    /// A daemon the app launched itself has no TERM at all, so passing the base
    /// through would leave the job's reader guessing.
    @Test func aDaemonWithNoTERMStillGivesTheJobOne() {
        #expect(
            SpawnBaseEnvironment.inheriting(Self.kept)
                == Self.kept.merging(Self.pinned) { _, pin in pin })
    }

    /// The pin is part of the inherited base, so a spawn that deliberately asks
    /// for a different terminal type still wins.
    @Test func aSpawnMayStillChooseItsOwnTERM() {
        let request = Self.launch(sensitiveEnv: ["TERM": "screen-256color"])

        #expect(request.environment["TERM"] == "screen-256color")
    }

    /// A profile-bound Claude session gets its config dir injected per spawn, so
    /// a daemon restarted from one carries that profile's credential and
    /// settings. A profile-less job that inherited it would run as somebody
    /// else's profile.
    @Test func aTBDMintedConfigDirDoesNotOutliveItsSpawn() {
        let base = Self.kept.merging(
            ["CLAUDE_CONFIG_DIR": "/tmp/example-tbd-home/profiles/0f0e-example/claude"]
        ) { _, minted in minted }

        let inherited = SpawnBaseEnvironment.inheriting(base)
        let expected = Self.kept
            .merging(Self.pinned) { _, pin in pin }
            .filter { $0.key != "CLAUDE_CONFIG_DIR" }

        #expect(inherited["CLAUDE_CONFIG_DIR"] == nil)
        #expect(inherited == expected)
    }

    /// "Under TBD's profiles directory" means *this* installation's, resolved
    /// from the base's own `TBD_HOME` — a daemon fenced onto a scratch home must
    /// not judge against some other installation's paths.
    @Test func theProfilesDirIsResolvedFromTheBasesOwnTBDHome() {
        let otherInstallation = Self.kept.merging([
            "TBD_HOME": "/tmp/other-home",
            "CLAUDE_CONFIG_DIR": "/tmp/example-tbd-home/profiles/x/claude",
        ]) { _, override in override }

        #expect(
            SpawnBaseEnvironment.inheriting(otherInstallation)["CLAUDE_CONFIG_DIR"]
                == "/tmp/example-tbd-home/profiles/x/claude")

        // With no TBD_HOME the fallback installation root is what decides, so
        // build the path from the same resolver rather than spelling out `~/tbd`.
        let defaultProfileDir = TBDConstants.configDir(environment: [:])
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("x", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: true)
            .path
        var noHome = Self.kept
        noHome.removeValue(forKey: "TBD_HOME")
        noHome["CLAUDE_CONFIG_DIR"] = defaultProfileDir

        #expect(SpawnBaseEnvironment.inheriting(noHome)["CLAUDE_CONFIG_DIR"] == nil)
    }

    /// Dropping the launcher's profile from the base must not cost a
    /// profile-bound spawn its own: that value arrives as `sensitiveEnv` and is
    /// merged on top of the scrubbed base.
    @Test func aProfileBoundSpawnStillReachesItsOwnConfigDir() {
        let launcherProfile = Self.kept.merging(
            ["CLAUDE_CONFIG_DIR": "/tmp/example-tbd-home/profiles/launcher/claude"]
        ) { _, launcher in launcher }
        let request = Self.launch(
            sensitiveEnv: ["CLAUDE_CONFIG_DIR": "/tmp/example-tbd-home/profiles/this-spawn/claude"],
            environment: launcherProfile)

        #expect(
            request.environment["CLAUDE_CONFIG_DIR"]
                == "/tmp/example-tbd-home/profiles/this-spawn/claude")
    }
}
