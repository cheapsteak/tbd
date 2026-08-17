import Foundation
import TBDShared

/// Builds the `--append-system-prompt` value for Claude sessions in TBD worktrees.
enum SystemPromptBuilder {

    /// Shell-escape a string for embedding in a single-quoted shell argument.
    static func shellEscape(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let defaultRenamePrompt = RepoConstants.defaultRenamePrompt

    /// Slim pointer injected via `--append-system-prompt` on fresh Claude
    /// sessions. The full TBD reference content lives in the `tbd` skill,
    /// loaded into the spawned session via `--plugin-dir` from
    /// `~/Library/Application Support/TBD/plugin/`.
    static var builtInTBDContext: String {
        """
        You are running inside a TBD-managed worktree (a macOS worktree + terminal manager).
        A `tbd` skill is available — invoke it for worktree/terminal actions.
        """
    }

    /// Layer injected for repo-less scratch sessions. Explains the space and
    /// nudges agent-driven promotion. This is the built-in default; callers
    /// may override it per-session via `promptLayers(scratchInstructions:)`.
    static var scratchContext: String { RepoConstants.defaultScratchInstructions }

    /// Returns the individual prompt layers as env-var-name → value pairs.
    /// Used both to set env vars in terminals and to build the combined `--append-system-prompt`.
    /// `scratchInstructions` is the global user-customizable override for the
    /// scratch layer (`Config.scratchInstructions`); `nil` or blank falls
    /// back to the built-in default. `scratchRenamePrompt` is the analogous
    /// global user-customizable override for the scratch rename-nudge layer
    /// (`Config.scratchRenamePrompt`); `nil` or blank falls back to
    /// `RepoConstants.defaultScratchRenamePrompt`.
    /// `supervisionPlaybook` is the resolved playbook a hosted desk or an
    /// appointed supervisor stands on, installed as a **standing conduct
    /// layer** (fleet-supervision design §5, §9; sweep-program design §8). Nil
    /// on every ordinary fleet spawn, which is all of them but a desk's.
    static func promptLayers(
        repo: Repo?, worktree: Worktree, scratchInstructions: String? = nil,
        scratchRenamePrompt: String? = nil, supervisionPlaybook: String? = nil
    ) -> [String: String] {
        var layers: [String: String] = [:]

        layers["TBD_PROMPT_CONTEXT"] = builtInTBDContext

        // The supervisor's standing conduct. Installed at launch rather than
        // sent as a message so compaction cannot eat it: a playbook embedded in
        // an early turn can be summarized into mush by briefing fifteen, while
        // a standing layer is re-included by construction.
        if let playbook = supervisionPlaybook?.trimmingCharacters(in: .whitespacesAndNewlines),
           !playbook.isEmpty {
            layers["TBD_PROMPT_SUPERVISION"] = supervisionPlaybook!
        }

        if worktree.isScratch {
            let trimmedCustom = scratchInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
            layers["TBD_PROMPT_SCRATCH"] = (trimmedCustom?.isEmpty == false) ? scratchInstructions! : scratchContext

            if worktree.hasDefaultDisplayName {
                let trimmedRename = scratchRenamePrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
                let renamePrompt = (trimmedRename?.isEmpty == false)
                    ? scratchRenamePrompt!
                    : RepoConstants.defaultScratchRenamePrompt
                if !renamePrompt.isEmpty {
                    layers["TBD_PROMPT_RENAME"] = renamePrompt
                }
            }
        }

        if !worktree.isScratch && worktree.status != .main && worktree.displayName == worktree.name {
            let renamePrompt = repo?.renamePrompt ?? defaultRenamePrompt
            if !renamePrompt.isEmpty {
                layers["TBD_PROMPT_RENAME"] = renamePrompt
            }
        }

        if let instructions = repo?.customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instructions.isEmpty {
            layers["TBD_PROMPT_INSTRUCTIONS"] = instructions
        }

        return layers
    }

    /// Build the combined system prompt for a Claude session.
    /// Returns nil if there's nothing to append (e.g., resume session).
    ///
    /// **This function hand-picks the layers it emits, so a layer added to
    /// `promptLayers` alone reaches the environment and nothing else.** Anything
    /// missing from the list below is silently dropped from
    /// `--append-system-prompt` — it compiles, it ships, and it delivers
    /// nothing. Add to both, and assert on the composed string rather than on
    /// the map.
    ///
    /// **Resume returns nil, and the supervision layer inherits that.** A
    /// conduct reload — resuming a desk's session with a refreshed playbook
    /// layer after the operator edits it (sweep-program design §8) — is
    /// therefore not yet wired: this slice installs the layer at spawn only.
    /// The shipped mechanism for a playbook edit under a live desk is the
    /// briefing header's conduct delta, which arrives with delivery. Nothing
    /// here was overlooked; the reload is deferred deliberately.
    static func build(
        repo: Repo?, worktree: Worktree, isResume: Bool, scratchInstructions: String? = nil,
        scratchRenamePrompt: String? = nil, supervisionPlaybook: String? = nil
    ) -> String? {
        if isResume { return nil }

        let layers = promptLayers(
            repo: repo, worktree: worktree, scratchInstructions: scratchInstructions,
            scratchRenamePrompt: scratchRenamePrompt, supervisionPlaybook: supervisionPlaybook
        )
        var parts: [String] = []

        // Order: scratch layer, rename prompt, TBD context, custom
        // instructions, standing supervision conduct. The playbook goes last
        // so that nothing generic follows the conduct a supervisor is meant to
        // act under.
        if let scratch = layers["TBD_PROMPT_SCRATCH"] { parts.append(scratch) }
        if let rename = layers["TBD_PROMPT_RENAME"] { parts.append(rename) }
        parts.append(builtInTBDContext)
        if let instructions = layers["TBD_PROMPT_INSTRUCTIONS"] { parts.append(instructions) }
        if let supervision = layers["TBD_PROMPT_SUPERVISION"] { parts.append(supervision) }

        return parts.isEmpty ? nil : parts.joined(separator: "\n\n---\n\n")
    }
}
