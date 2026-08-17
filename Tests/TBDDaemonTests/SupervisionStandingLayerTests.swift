import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The desk's standing conduct layer, `TBD_PROMPT_SUPERVISION`.
///
/// **The assertion that matters is the composed string, not the map.**
/// `SystemPromptBuilder.build` hand-picks the layers it emits, so a layer added
/// to `promptLayers` alone reaches the environment and is silently dropped from
/// `--append-system-prompt` — it compiles, it ships, and the desk stands on
/// nothing. Every test here that could be satisfied by the map is paired with
/// one that reads the flag the agent actually launches with.
///
/// Tier 1 — pure string composition, no filesystem, no clocks.
@Suite("Supervision standing layer")
struct SupervisionStandingLayerTests {

    private static let playbook = "# Conduct\n\nEscalate instead of guessing."

    private static func scratch() -> Worktree {
        Worktree(
            repoID: nil, name: "supervision-desk", displayName: "Supervisor · acme-web",
            branch: "", path: "/tmp/x-scratch/supervision-desk", tmuxServer: "tbd-scratch")
    }

    // MARK: - The layer

    @Test("The playbook becomes the TBD_PROMPT_SUPERVISION layer")
    func layerIsNamed() {
        let layers = SystemPromptBuilder.promptLayers(
            repo: nil, worktree: Self.scratch(), supervisionPlaybook: Self.playbook)
        #expect(layers["TBD_PROMPT_SUPERVISION"] == Self.playbook)
    }

    @Test("No playbook, no layer — every ordinary fleet spawn is unchanged")
    func absentWithoutAPlaybook() {
        let layers = SystemPromptBuilder.promptLayers(repo: nil, worktree: Self.scratch())
        #expect(layers["TBD_PROMPT_SUPERVISION"] == nil)
        let built = SystemPromptBuilder.build(
            repo: nil, worktree: Self.scratch(), isResume: false)
        #expect(built?.contains("Escalate instead of guessing") != true)
    }

    @Test("A blank playbook installs no layer — whitespace is not conduct")
    func blankPlaybookInstallsNothing() {
        let layers = SystemPromptBuilder.promptLayers(
            repo: nil, worktree: Self.scratch(), supervisionPlaybook: "  \n\t ")
        #expect(layers["TBD_PROMPT_SUPERVISION"] == nil)
    }

    // MARK: - The trap: it has to reach the composed prompt

    @Test("The playbook text reaches the built system prompt, not just the map")
    func reachesTheBuiltPrompt() throws {
        let built = try #require(SystemPromptBuilder.build(
            repo: nil, worktree: Self.scratch(), isResume: false,
            supervisionPlaybook: Self.playbook))
        #expect(built.contains("Escalate instead of guessing"))
        // The generic layers still ship beside it — the standing layer is
        // installed, never exclusive.
        #expect(built.contains("TBD-managed worktree"))
    }

    @Test("The playbook text reaches the --append-system-prompt flag Claude launches with")
    func reachesTheSpawnFlag() throws {
        let appendPrompt = SystemPromptBuilder.build(
            repo: nil, worktree: Self.scratch(), isResume: false,
            supervisionPlaybook: Self.playbook)
        let spawn = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: UUID().uuidString,
            appendSystemPrompt: appendPrompt,
            initialPrompt: nil,
            profileSecret: nil,
            cmd: nil,
            shellFallback: "/bin/zsh")
        #expect(spawn.command.contains("--append-system-prompt"))
        #expect(spawn.command.contains("Escalate instead of guessing"))
    }

    @Test("A resume appends nothing, playbook or not — the conduct reload is deferred")
    func resumeStillAppendsNothing() {
        // Not an oversight: this slice installs the layer at spawn only. The
        // shipped mechanism for a playbook edit under a live desk is the
        // briefing header's conduct delta, which arrives with delivery.
        let built = SystemPromptBuilder.build(
            repo: nil, worktree: Self.scratch(), isResume: true,
            supervisionPlaybook: Self.playbook)
        #expect(built == nil)
    }
}
