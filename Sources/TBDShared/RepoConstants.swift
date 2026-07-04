import Foundation

public enum RepoConstants {
    public static let defaultRenamePrompt = """
        Only if `git branch --show-current` starts with `tbd/`:

        1. Rename the git branch to reflect the task:
           git branch -m <new-branch-name>

        2. Rename the TBD worktree display name:
           tbd worktree rename "$(basename "$(git rev-parse --show-toplevel)")" "<emoji> <display name>"

        Branch naming: use kebab-case, be concise (<30 chars), be specific.
        Display name: pick a relevant emoji, convert branch name to title case with spaces.

        Examples:
          Branch: fix-login-timeout → Display: ⏱ Fix Login Timeout
          Branch: add-export-csv   → Display: 📊 Add Export CSV

        Do this immediately, before reading files, using skills, or any other tools.
        """

    /// Layer injected for repo-less scratch sessions. Explains the space and
    /// nudges agent-driven promotion. User-overridable via the global
    /// `Config.scratchInstructions` setting.
    public static let defaultScratchInstructions = """
        You are in a TBD **scratch space** — a repo-less workspace with no git repo yet.
        Use it to bootstrap a new project or hold a general-purpose chat.
        When the project takes shape, offer the user promotion: ask them for a \
        destination path, then run `tbd scratch promote <dest-path>` from this \
        session. That moves the folder and registers it as a real TBD repo.
        """

    /// Layer injected for repo-less scratch sessions once their default display
    /// name hasn't been customized yet — nudges the agent to rename the SPACE
    /// (not a git branch; there is none) once its topic becomes clear. Mirrors
    /// `defaultRenamePrompt` but scratch-flavored. User-overridable via the
    /// global `Config.scratchRenamePrompt` setting.
    public static let defaultScratchRenamePrompt = """
        Once this scratch space's topic becomes clear, rename it to reflect
        what it's about:

        tbd worktree rename "$(basename "$PWD")" "<emoji> <Title>"

        This renames the TBD scratch space itself, not a git branch — there is
        no repo here yet. Pick a relevant emoji, then a short, specific title
        in title case.

        Examples:
          Topic: debugging a login timeout  → 🐛 Login Timeout Debug
          Topic: exploring a CSV exporter   → 📊 CSV Export Exploration

        Do this once the topic is clear — it doesn't need to block other work.
        """
}
