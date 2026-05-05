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
    /// sessions. The full TBD reference content lives in the `tbd` skill
    /// (registered at `~/.claude/skills/tbd/SKILL.md` after the user clicks
    /// "Install TBD Skill" in the menu) and at the failsafe path resolved below.
    static var builtInTBDContext: String {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.path
            ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support")
        let fallback = appSupport + "/TBD/skill/SKILL.md"
        return """
            You are running inside a TBD-managed worktree (a macOS worktree + terminal manager).
            A `tbd` skill should be available — invoke it for worktree/terminal actions.
            If unavailable, read its content directly from \(fallback).
            """
    }

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
