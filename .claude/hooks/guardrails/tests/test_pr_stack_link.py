import os
import sys
import unittest

_HOOKS_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if _HOOKS_DIR not in sys.path:
    sys.path.insert(0, _HOOKS_DIR)

from guardrails.rules.pr_stack_link import PRStackLinkRule  # noqa: E402
from guardrails.rules.pr_worktree_link import MCP_CREATE_PR_TOOL  # noqa: E402


def _check(command, tool_name=None):
    ctx = {"cwd": "/repo"}
    if tool_name is not None:
        ctx["tool_name"] = tool_name
    return PRStackLinkRule().check({"command": command}, ctx)


def _check_mcp(**fields):
    tool_input = {"owner": "acme", "repo": "acme-prod", "title": "feat: x", "body": "y", "head": "feat-b"}
    tool_input.update(fields)
    return PRStackLinkRule().check(tool_input, {"cwd": "/repo", "tool_name": MCP_CREATE_PR_TOOL})


class PRStackLinkBashTests(unittest.TestCase):
    def _informs(self, command, **kwargs):
        decision = _check(command, **kwargs)
        self.assertIsNotNone(decision, command)
        assert decision is not None
        self.assertEqual(decision.action, "info", command)
        return decision

    def test_spaced_base_informs(self):
        self._informs("gh pr create --base feat-a --title 'feat: x' --body y")

    def test_equals_joined_base_informs(self):
        self._informs("gh pr create --base=feat-a --title 'feat: x'")

    def test_short_base_informs(self):
        self._informs("gh pr create -B feat-a --fill")
        self._informs("gh pr create -B=feat-a --fill")

    def test_explicit_bash_tool_name_informs(self):
        # The dispatcher always sets tool_name; a missing one reads as Bash.
        self._informs("gh pr create --base feat-a", tool_name="Bash")

    def test_path_qualified_gh_informs(self):
        self._informs("/opt/homebrew/bin/gh pr create --base feat-a")
        self._informs("gh -R acme/acme-prod pr create --base feat-a")

    def test_main_base_silent(self):
        self.assertIsNone(_check("gh pr create --base main --title 'feat: x' --body y"))
        self.assertIsNone(_check("gh pr create -B main --fill"))
        self.assertIsNone(_check("gh pr create --base=main --fill"))

    def test_no_base_silent(self):
        self.assertIsNone(_check("gh pr create --title 'feat: x' --body y"))
        self.assertIsNone(_check("gh pr create --fill"))

    def test_last_base_wins(self):
        # gh sends the final --base, so only it decides; the spellings alias.
        self.assertIsNone(_check("gh pr create --base feat-a --base main"))
        self._informs("gh pr create --base main -B feat-a")

    def test_mention_in_heredoc_body_silent(self):
        command = "cat <<'EOF' > notes.md\nOpen it with gh pr create --base feat-a.\nEOF"
        self.assertIsNone(_check(command))

    def test_mention_in_a_create_body_heredoc_silent(self):
        command = (
            "gh pr create --base main --title 'feat: x' --body \"$(cat <<'EOF'\n"
            "The next PR goes up with gh pr create --base feat-a.\n"
            "EOF\n"
            ')"'
        )
        self.assertIsNone(_check(command))

    def test_quoted_mention_silent(self):
        self.assertIsNone(_check("echo 'gh pr create --base feat-a'"))
        self.assertIsNone(_check("gh pr create --title 'gh pr create --base feat-a'"))

    def test_one_off_trunk_create_in_a_chain_informs(self):
        self._informs(
            "gh pr create --base main --title 'feat: a' && "
            "gh pr create --base feat-a --title 'feat: b'"
        )

    def test_chain_of_trunk_creates_silent(self):
        self.assertIsNone(
            _check("gh pr create --base main --title a && gh pr create --title b")
        )

    def test_gh_stack_silent(self):
        self.assertIsNone(_check("gh stack link 1 2 3"))
        self.assertIsNone(_check("gh stack link feat-a feat-b"))
        self.assertIsNone(_check("gh stack merge 3 --squash --yes"))

    def test_unrelated_commands_silent(self):
        self.assertIsNone(_check("gh pr view 12"))
        self.assertIsNone(_check("gh pr edit 12 --base feat-a"))
        self.assertIsNone(_check("git push -u origin feat-b"))


class PRStackLinkMCPTests(unittest.TestCase):
    def test_off_trunk_base_informs(self):
        decision = _check_mcp(base="feat-a")
        assert decision is not None
        self.assertEqual(decision.action, "info")

    def test_main_base_silent(self):
        self.assertIsNone(_check_mcp(base="main"))

    def test_missing_or_empty_base_silent(self):
        self.assertIsNone(_check_mcp())
        self.assertIsNone(_check_mcp(base=""))
        self.assertIsNone(_check_mcp(base=None))

    def test_reads_fields_not_a_command(self):
        # An MCP call has no command; a stray one must not be tokenized.
        self.assertIsNone(_check_mcp(base="main", command="gh pr create --base feat-a"))


class PRStackLinkMessageTests(unittest.TestCase):
    def test_message_teaches_the_whole_route(self):
        decision = _check("gh pr create --base feat-a")
        assert decision is not None
        reason = decision.reason
        self.assertTrue(reason.startswith("[pr-stack-link] "))
        for needle in (
            "gh stack link",
            "repos/{owner}/{repo}/stacks",
            "X-GitHub-Api-Version: 2026-03-10",
            '{"pull_requests":[',
            "ask a human",
            "gh workflow run test.yml",
            "gh stack merge <top> --squash",
            "never PR by PR",
            "stacked-prs",
            "nothing is blocked",
        ):
            self.assertIn(needle, reason)

    def test_tools(self):
        self.assertEqual(PRStackLinkRule.tools, {"Bash", MCP_CREATE_PR_TOOL})

    def test_never_denies(self):
        for command in (
            "gh pr create --base feat-a",
            "gh pr create --base main",
            "gh pr create",
            "gh stack link 1 2 3",
            "cat <<'EOF'\ngh pr create --base feat-a\nEOF",
        ):
            decision = _check(command)
            if decision is not None:
                self.assertNotEqual(decision.action, "deny", command)
        for base in ("feat-a", "main", None):
            decision = _check_mcp(base=base)
            if decision is not None:
                self.assertNotEqual(decision.action, "deny", base)


if __name__ == "__main__":
    unittest.main()
