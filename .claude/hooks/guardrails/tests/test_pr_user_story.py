import os
import sys
import tempfile
import unittest

_HOOKS_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if _HOOKS_DIR not in sys.path:
    sys.path.insert(0, _HOOKS_DIR)

from guardrails.rules import pr_user_story  # noqa: E402
from guardrails.rules.pr_user_story import PRUserStoryRule  # noqa: E402
from guardrails.rules.pr_worktree_link import MCP_CREATE_PR_TOOL  # noqa: E402

_STORY = "## User story\n\nAs a reviewer, I want a story, so that I can judge the PR.\n\n## Summary\n\nx\n"
_TEMPLATE_ONLY = "## User story\n\n<!-- As a <who>, I want <what>, so that <why>. -->\n\n## Summary\n\nx\n"


def _check(command):
    return PRUserStoryRule().check({"command": command}, {"cwd": "/repo"})


def _check_mcp(**fields):
    tool_input = {"owner": "acme", "repo": "acme-prod", "head": "feat-b", "base": "main"}
    tool_input.update(fields)
    return PRUserStoryRule().check(tool_input, {"cwd": "/repo", "tool_name": MCP_CREATE_PR_TOOL})


class PRUserStoryRuleTests(unittest.TestCase):
    def _informs(self, command):
        decision = _check(command)
        self.assertIsNotNone(decision, command)
        assert decision is not None
        self.assertEqual(decision.action, "info", command)
        self.assertIn("## User story", decision.reason)
        self.assertIn("As a <who>", decision.reason)
        self.assertIn("When <situation>", decision.reason)
        return decision

    def test_loads_the_ci_script(self):
        # The rule must share the CI script's logic, not silently go inert.
        self.assertTrue(os.path.isfile(pr_user_story.CHECK_SCRIPT))
        self.assertIsNotNone(pr_user_story._load_check())

    def test_feature_without_body_informs(self):
        self._informs("gh pr create --title 'feat: thing'")

    def test_mixed_case_feat_informs(self):
        self._informs("gh pr create --title 'Feat: thing' --body 'Summary only'")

    def test_untyped_title_informs(self):
        self._informs("gh pr create -t 'Add a thing' -b 'no story here'")

    def test_scoped_bang_feature_informs(self):
        self._informs("gh pr create --title 'feat(app)!: thing' --body 'x'")

    def test_template_comment_only_informs(self):
        self._informs(f"gh pr create --title 'feat: thing' --body '{_TEMPLATE_ONLY}'")

    def test_filled_inline_body_silent(self):
        self.assertIsNone(_check(f"gh pr create --title 'feat: thing' --body '{_STORY}'"))

    def test_equals_joined_flags(self):
        self.assertIsNone(_check(f"gh pr create --title='feat: x' --body='{_STORY}'"))

    def test_alias_heading_silent(self):
        body = "## Job to be done\n\nWhen I ship, I want to explain, so I can be reviewed."
        self.assertIsNone(_check(f"gh pr create --title 'feat: x' --body '{body}'"))

    def test_exempt_titles_silent(self):
        for title in ("fix: x", "Fix(app): x", "docs!: x", "chore: x", "test: x", "ci: x", "build: x", "revert: x"):
            with self.subTest(title=title):
                self.assertIsNone(_check(f"gh pr create --title '{title}' --body 'no story'"))

    def test_no_title_silent(self):
        self.assertIsNone(_check("gh pr create --fill"))

    def test_substituted_title_silent(self):
        self.assertIsNone(_check('gh pr create --title "$(git log -1 --format=%s)" --body x'))

    def test_body_file_with_story_silent(self):
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as handle:
            handle.write(_STORY)
        try:
            self.assertIsNone(_check(f"gh pr create --title 'feat: x' --body-file {handle.name}"))
            self.assertIsNone(_check(f"gh pr create --title 'feat: x' -F {handle.name}"))
        finally:
            os.unlink(handle.name)

    def test_body_file_without_story_informs(self):
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as handle:
            handle.write(_TEMPLATE_ONLY)
        try:
            self._informs(f"gh pr create --title 'feat: x' --body-file {handle.name}")
        finally:
            os.unlink(handle.name)

    def test_missing_body_file_informs(self):
        self._informs("gh pr create --title 'feat: x' --body-file /nonexistent/pr-body.md")

    def test_heredoc_body_with_story_silent(self):
        command = (
            "gh pr create --title 'feat: x' --body \"$(cat <<'EOF'\n"
            + _STORY
            + "EOF\n)\""
        )
        self.assertIsNone(_check(command))

    def test_heredoc_body_without_story_informs(self):
        command = "gh pr create --title 'feat: x' --body \"$(cat <<'EOF'\n## Summary\n\nx\nEOF\n)\""
        self._informs(command)

    def test_stdin_body_file_from_heredoc_silent(self):
        command = "gh pr create --title 'feat: x' -F - <<'EOF'\n" + _STORY + "EOF"
        self.assertIsNone(_check(command))

    def test_each_create_judged_on_its_own(self):
        command = (
            f"gh pr create --title 'feat: a' --body '{_STORY}' && "
            "gh pr create --title 'feat: b' --body 'none'"
        )
        self._informs(command)

    def test_mention_in_heredoc_prose_silent(self):
        command = "cat <<'EOF' > notes.md\nRun gh pr create --title 'feat: x' to open it.\nEOF"
        self.assertIsNone(_check(command))

    def test_quoted_mention_silent(self):
        self.assertIsNone(_check("echo 'gh pr create --title feat:x'"))

    def test_unrelated_commands_silent(self):
        self.assertIsNone(_check("gh pr view 12"))
        self.assertIsNone(_check("git commit -m 'feat: x'"))
        self.assertIsNone(_check("glab mr create --title 'feat: x'"))

    def test_last_body_wins(self):
        command = f"gh pr create --title 'feat: x' --body '{_STORY}' --body 'replaced'"
        self._informs(command)


class PRUserStoryMCPTests(unittest.TestCase):
    def _informs(self, **fields):
        decision = _check_mcp(**fields)
        self.assertIsNotNone(decision, fields)
        assert decision is not None
        self.assertEqual(decision.action, "info", fields)
        self.assertIn("## User story", decision.reason)
        return decision

    def test_feature_without_story_informs(self):
        self._informs(title="feat: thing", body="## Summary\n\nx\n")
        self._informs(title="feat: thing", body=_TEMPLATE_ONLY)

    def test_feature_without_body_informs(self):
        self._informs(title="feat: thing")

    def test_exempt_title_silent(self):
        self.assertIsNone(_check_mcp(title="fix: thing", body="no story"))
        self.assertIsNone(_check_mcp(title="docs(app): thing", body="no story"))

    def test_filled_story_silent(self):
        self.assertIsNone(_check_mcp(title="feat: thing", body=_STORY))

    def test_missing_or_empty_title_silent(self):
        self.assertIsNone(_check_mcp(body="no story"))
        self.assertIsNone(_check_mcp(title="", body="no story"))

    def test_reads_fields_not_a_command(self):
        # An MCP call has no command; a stray one must not be tokenized.
        self.assertIsNone(
            _check_mcp(title="fix: x", body="no story", command="gh pr create --title 'feat: x'")
        )


if __name__ == "__main__":
    unittest.main()
