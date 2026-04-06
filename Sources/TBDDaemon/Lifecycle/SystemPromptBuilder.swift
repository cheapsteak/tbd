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
        - tbd worktree list [--repo <id>] — list worktrees
        - tbd terminal create <worktree> [--cmd <command>] — create a new terminal
        - tbd terminal output <terminal-id> [--lines N] — read terminal output
        - tbd notify --type <type> [--message <msg>] — send notifications to TBD UI
          Types: response_complete, error, task_complete, attention_needed

        Environment variables:
        - TBD_WORKTREE_ID — UUID of the current worktree (auto-set in all TBD terminals)
        - TBD_PROMPT_CONTEXT — Built-in TBD context (this text), for passing to spawned sessions
        - TBD_PROMPT_INSTRUCTIONS — Per-repo custom instructions (set if configured)
        - TBD_PROMPT_RENAME — Worktree rename prompt (set if worktree hasn't been renamed yet)

        To spawn a new Claude session tab with a custom prompt:
          tbd terminal create "$TBD_WORKTREE_ID" --cmd "claude --prompt 'your task here' --append-system-prompt \\"$TBD_PROMPT_CONTEXT\\""
        """

    /// Build the combined system prompt for a Claude session.
    /// Returns nil if there's nothing to append (e.g., resume session).
    static func build(repo: Repo, worktree: Worktree, isResume: Bool) -> String? {
        if isResume { return nil }

        var parts: [String] = []

        // Layer 1: Rename prompt (conditional on worktree not yet renamed)
        if worktree.displayName == worktree.name {
            let renamePrompt = repo.renamePrompt ?? defaultRenamePrompt
            if !renamePrompt.isEmpty {
                parts.append(renamePrompt)
            }
        }

        // Layer 2: Built-in TBD context (always)
        parts.append(builtInTBDContext)

        // Layer 3: User general instructions (if set)
        if let instructions = repo.customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instructions.isEmpty {
            parts.append(instructions)
        }

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
