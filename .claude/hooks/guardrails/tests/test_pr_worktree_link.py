import os
import sys
import tempfile
import unittest
from unittest import mock

_HOOKS_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if _HOOKS_DIR not in sys.path:
    sys.path.insert(0, _HOOKS_DIR)

from guardrails.rules.pr_worktree_link import PRWorktreeLinkRule  # noqa: E402

_TBD_HOME = "/tmp/pr-worktree-link-tests/tbd"
_IN_WORKTREE = os.path.join(_TBD_HOME, "worktrees", "tbd", "some-branch")
_OUTSIDE = "/tmp/pr-worktree-link-tests/elsewhere"


# The rule reads TBD_WORKTREE_ID / TBD_HOME inside check(), so patch.dict here
# actually takes effect; a module-level constant would be frozen at import.
def _env(worktree_id=None, tbd_home=_TBD_HOME):
    values = {"TBD_HOME": tbd_home}
    if worktree_id is not None:
        values["TBD_WORKTREE_ID"] = worktree_id
    patcher = mock.patch.dict(os.environ, values, clear=False)
    return patcher


def _check(command, cwd=_IN_WORKTREE, worktree_id=None, tbd_home=_TBD_HOME):
    with _env(worktree_id=worktree_id, tbd_home=tbd_home):
        # A real TBD_WORKTREE_ID in the developer's shell would mask the
        # cwd-based branch, so drop it unless the case supplies one.
        if worktree_id is None:
            os.environ.pop("TBD_WORKTREE_ID", None)
        return PRWorktreeLinkRule().check({"command": command}, {"cwd": cwd})


class PRWorktreeLinkTests(unittest.TestCase):
    def test_informs_on_bare_gh_pr_create_in_worktree(self):
        d = _check("gh pr create --title 'feat: thing'")
        assert d is not None
        self.assertEqual(d.action, "info")
        self.assertIn("?worktree=", d.reason)
        self.assertIn("tbd link", d.reason)

    def test_informs_when_only_env_marks_the_session(self):
        d = _check("gh pr create", cwd=_OUTSIDE, worktree_id="1234-abcd")
        assert d is not None
        self.assertEqual(d.action, "info")

    def test_silent_when_inline_body_already_has_link(self):
        self.assertIsNone(
            _check(
                "gh pr create --body 'Summary\n\n"
                "[my-worktree](https://cheapsteak.github.io/tbd/open/?worktree=abc)'"
            )
        )

    def test_silent_when_body_file_already_has_link(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "body.md")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(
                    "Summary\n\n[my-worktree](https://cheapsteak.github.io/tbd/open/?worktree=abc)\n"
                )
            self.assertIsNone(_check(f"gh pr create --body-file {path}"))
            self.assertIsNone(_check(f'gh pr create --body-file="{path}"'))
            self.assertIsNone(_check(f"gh pr create -F {path}"))

    def test_informs_when_body_file_lacks_link(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "body.md")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("Summary\n\nNo link here.\n")
            d = _check(f"gh pr create --body-file {path}")
            assert d is not None
            self.assertEqual(d.action, "info")

    def test_informs_when_body_file_is_unreadable(self):
        d = _check("gh pr create --body-file /nonexistent/definitely/not/here.md")
        assert d is not None
        self.assertEqual(d.action, "info")

    def test_silent_for_non_gh_pr_create_command(self):
        self.assertIsNone(_check("gh pr list"))
        self.assertIsNone(_check("git commit -m 'feat: thing'"))

    def test_informs_after_a_command_separator(self):
        d = _check("git push -u origin HEAD && gh pr create --fill")
        assert d is not None
        self.assertEqual(d.action, "info")

    def test_silent_for_a_mid_line_mention(self):
        # A quoted or backticked mention (commit message, heredoc prose) is not
        # an invocation.
        self.assertIsNone(_check("git commit -m 'docs: explain `gh pr create` usage'"))

    def test_silent_outside_tbd(self):
        self.assertIsNone(_check("gh pr create", cwd=_OUTSIDE))

    def test_tolerates_global_flags_between_gh_and_pr(self):
        d = _check("gh --repo owner/name pr create --fill")
        assert d is not None
        self.assertEqual(d.action, "info")

    def test_never_denies(self):
        commands = (
            "gh pr create",
            "gh pr create --body 'has ?worktree=abc'",
            "gh pr create --body-file /nonexistent/x.md",
            "gh pr list",
        )
        for command in commands:
            for cwd in (_IN_WORKTREE, _OUTSIDE):
                d = _check(command, cwd=cwd)
                if d is not None:
                    self.assertNotEqual(d.action, "deny", command)


if __name__ == "__main__":
    unittest.main()
