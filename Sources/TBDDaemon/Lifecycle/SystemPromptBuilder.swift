import Foundation
import TBDShared

/// Builds the `--append-system-prompt` value for Claude sessions in TBD worktrees.
enum SystemPromptBuilder {

    /// Shell-escape a string for embedding in a single-quoted shell argument.
    static func shellEscape(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let defaultRenamePrompt = RepoConstants.defaultRenamePrompt

    static let builtInTBDContext = """
        You are running inside a TBD-managed worktree. TBD is a macOS worktree + terminal manager.

        Available CLI commands:
        - tbd worktree rename "<worktree-name>" "<display-name>" — rename the worktree display name
        - tbd worktree create [--repo <path-or-id>] — create a new worktree (auto-named)
        - tbd worktree list [--repo <id>] — list worktrees
        - tbd terminal create <worktree> [--type claude|shell] [--cmd <command>] — create a new terminal tab
        - tbd terminal send --terminal <id> --text <text> [--submit] — send text to a terminal (--submit presses Enter)
        - tbd terminal output <terminal-id> [--lines N] — read terminal output
        - tbd notify --type <type> [--message <msg>] — send notifications to TBD UI
          Types: response_complete, error, task_complete, attention_needed

        Environment variables:
        - TBD_WORKTREE_ID — UUID of the current worktree (auto-set in all TBD terminals)
        - TBD_PROMPT_CONTEXT — Built-in TBD context (this text), for passing to spawned sessions
        - TBD_PROMPT_INSTRUCTIONS — Per-repo custom instructions (set if configured)
        - TBD_PROMPT_RENAME — Worktree rename prompt (set if worktree hasn't been renamed yet)

        Spawning a new Claude tab in the current worktree:
          tbd terminal create "$TBD_WORKTREE_ID" --type claude --prompt "your task here"

        Creating a new worktree with an initial task for its default Claude tab:
          tbd worktree create --prompt "your task here"

        Using --cmd for full control (env vars expand in the new shell):
          tbd terminal create "$TBD_WORKTREE_ID" --cmd 'claude --append-system-prompt "$TBD_PROMPT_CONTEXT"'
        """

    /// Returns the individual prompt layers as env-var-name → value pairs.
    /// Used both to set env vars in terminals and to build the combined `--append-system-prompt`.
    static func promptLayers(repo: Repo?, worktree: Worktree) -> [String: String] {
        var layers: [String: String] = [:]

        layers["TBD_PROMPT_CONTEXT"] = builtInTBDContext

        if worktree.status != .main && worktree.displayName == worktree.name {
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
    static func build(repo: Repo, worktree: Worktree, isResume: Bool) -> String? {
        if isResume { return nil }

        let layers = promptLayers(repo: repo, worktree: worktree)
        var parts: [String] = []

        // Order: rename prompt, TBD context, custom instructions
        if let rename = layers["TBD_PROMPT_RENAME"] { parts.append(rename) }
        parts.append(builtInTBDContext)
        if let instructions = layers["TBD_PROMPT_INSTRUCTIONS"] { parts.append(instructions) }

        return parts.isEmpty ? nil : parts.joined(separator: "\n\n---\n\n")
    }

    /// Build the system prompt for a conductor session.
    /// Always includes TBD context; adds custom instructions for single-repo conductors.
    static func buildForConductor(repo: Repo?) -> String {
        var parts = [builtInTBDContext]

        if let instructions = repo?.customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instructions.isEmpty {
            parts.append(instructions)
        }

        return parts.joined(separator: "\n\n---\n\n")
    }
}
