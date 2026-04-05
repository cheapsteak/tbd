import Foundation

public enum RepoConstants {
    public static let defaultRenamePrompt = """
        To do immediately, before any other work:

        1. Rename the git branch to reflect the task:
           git branch -m <new-branch-name>

        2. Rename the TBD worktree display name:
           tbd worktree rename "$(basename "$(git rev-parse --show-toplevel)")" "<emoji> <display name>"

        Branch naming: use kebab-case, be concise (<30 chars), be specific.
        Display name: pick a relevant emoji, convert branch name to title case with spaces.

        Examples:
          Branch: fix-login-timeout → Display: ⏱ Fix Login Timeout
          Branch: add-export-csv   → Display: 📊 Add Export CSV

        Do this before reading files, using skills, or any other tools.
        """
}
