import os
import sys
import tempfile
import threading
import unittest
from unittest import mock

_HOOKS_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if _HOOKS_DIR not in sys.path:
    sys.path.insert(0, _HOOKS_DIR)

from guardrails.rules.pr_worktree_link import (  # noqa: E402
    _MAX_BODY_BYTES,
    PRWorktreeLinkRule,
    _file_has_link,
)

_TBD_HOME = "/tmp/pr-worktree-link-tests/tbd"
_IN_WORKTREE = os.path.join(_TBD_HOME, "worktrees", "tbd", "some-branch")
_OUTSIDE = "/tmp/pr-worktree-link-tests/elsewhere"
_LINK = "https://cheapsteak.github.io/tbd/open/?worktree=abc"


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


def _informs(testcase, command, **kwargs):
    decision = _check(command, **kwargs)
    testcase.assertIsNotNone(decision, command)
    testcase.assertEqual(decision.action, "info", command)
    return decision


class PRWorktreeLinkTests(unittest.TestCase):
    def test_informs_on_bare_gh_pr_create_in_worktree(self):
        d = _informs(self, "gh pr create --title 'feat: thing'")
        self.assertIn("?worktree=", d.reason)
        self.assertIn("tbd link", d.reason)

    def test_informs_when_only_env_marks_the_session(self):
        _informs(self, "gh pr create", cwd=_OUTSIDE, worktree_id="1234-abcd")

    def test_silent_when_inline_body_already_has_link(self):
        self.assertIsNone(_check(f"gh pr create --body 'Summary\n\n[my-worktree]({_LINK})'"))

    def test_silent_when_only_the_bare_scheme_is_in_the_body(self):
        # `tbd link` prints the `tbd://` form; pasting that straight in counts.
        self.assertIsNone(_check("gh pr create --body 'see tbd://open?worktree=abc'"))

    def test_silent_when_link_is_inside_a_heredoc_body(self):
        command = (
            "gh pr create --title x --body \"$(cat <<'EOF'\n"
            "Summary\n\n"
            f"[my-worktree]({_LINK})\n"
            "EOF\n"
            ')"'
        )
        self.assertIsNone(_check(command))

    def test_silent_when_link_only_appears_in_a_written_heredoc_body(self):
        # The link check scans the RAW command, not the heredoc-stripped text:
        # here the body file is written by the heredoc in the same command, so
        # the only copy of the link lives in a body the stripper drops.
        command = (
            "cat <<'EOF' > /nonexistent/pr-worktree-link-body.md\n"
            f"[my-worktree]({_LINK})\n"
            "EOF\n"
            "gh pr create --body-file /nonexistent/pr-worktree-link-body.md\n"
        )
        self.assertIsNone(_check(command))

    def test_silent_when_body_file_already_has_link(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "body.md")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(f"Summary\n\n[my-worktree]({_LINK})\n")
            self.assertIsNone(_check(f"gh pr create --body-file {path}"))
            self.assertIsNone(_check(f'gh pr create --body-file="{path}"'))
            self.assertIsNone(_check(f"gh pr create -F {path}"))
            self.assertIsNone(_check(f"gh pr create -F={path}"))

    def test_silent_when_body_file_path_contains_spaces(self):
        # A regex over the raw command truncates the path at the first space and
        # then nudges on a body that already has the link.
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "pr body.md")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(f"[my-worktree]({_LINK})\n")
            self.assertIsNone(_check(f'gh pr create --body-file "{path}"'))
            self.assertIsNone(_check(f'gh pr create --body-file="{path}"'))

    def test_informs_when_body_file_lacks_link(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "body.md")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("Summary\n\nNo link here.\n")
            _informs(self, f"gh pr create --body-file {path}")

    def test_informs_when_body_file_is_unreadable(self):
        _informs(self, "gh pr create --body-file /nonexistent/definitely/not/here.md")

    def test_body_file_read_is_bounded(self):
        # The hook blocks the Bash call while it runs, so it reads a capped
        # prefix. A link past the cap is not seen, and the nudge still fires.
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "huge.md")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("x" * (_MAX_BODY_BYTES + 4096))
                handle.write(f"\n[my-worktree]({_LINK})\n")
            _informs(self, f"gh pr create --body-file {path}")

    def test_non_regular_body_file_is_never_opened(self):
        # Opening a fifo with no writer blocks forever; the hook must not hang.
        if not hasattr(os, "mkfifo"):
            self.skipTest("no mkfifo on this platform")
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "body.fifo")
            os.mkfifo(path)
            result = []
            worker = threading.Thread(target=lambda: result.append(_file_has_link(path)))
            worker.daemon = True
            worker.start()
            worker.join(5)
            self.assertFalse(worker.is_alive(), "reading a fifo hung the guardrail")
            self.assertEqual(result, [False])

    def test_silent_for_non_gh_pr_create_command(self):
        self.assertIsNone(_check("gh pr list"))
        self.assertIsNone(_check("gh pr view 12"))
        self.assertIsNone(_check("gh pr edit 12 --body x"))
        self.assertIsNone(_check("git commit -m 'feat: thing'"))
        self.assertIsNone(_check("echo gh-pr-create"))

    def test_informs_after_a_command_separator(self):
        _informs(self, "git push -u origin HEAD && gh pr create --fill")
        _informs(self, "cd /tmp && gh  pr   create -t x")

    def test_silent_for_a_quoted_mention(self):
        # A quoted mention (commit message, grep pattern) is an argument, not an
        # invocation — and a separator inside the quotes must not manufacture a
        # segment either.
        self.assertIsNone(_check("git commit -m 'docs: explain `gh pr create` usage'"))
        self.assertIsNone(_check('grep -rn "gh pr create" docs/'))
        self.assertIsNone(_check('echo "x && gh pr create"'))

    def test_silent_for_a_heredoc_body_mention(self):
        # Heredoc bodies are prose the command writes, not commands it runs.
        self.assertIsNone(
            _check("cat <<'EOF' | tee -a CONTRIBUTING.md\nTo open a PR:\ngh pr create --fill\nEOF")
        )
        self.assertIsNone(_check("cat <<EOF > docs/howto.md\ngh pr create --fill\nEOF"))
        self.assertIsNone(_check("cat <<-EOF > docs/howto.md\n\tgh pr create --fill\n\tEOF"))

    def test_informs_after_a_heredoc_terminator(self):
        # The real invocation on the far side of a heredoc still counts.
        command = (
            "cat <<'EOF' > /tmp/body.md\n"
            "Some body text mentioning gh pr create\n"
            "EOF\n"
            "gh pr create --title x\n"
        )
        _informs(self, command)

    def test_tolerates_global_flags_between_gh_and_pr(self):
        _informs(self, "gh --repo owner/name pr create --fill")
        # `-R` takes a value, so its argument must not be read as the subcommand.
        _informs(self, "gh -R owner/name pr create --fill")

    def test_informs_for_a_path_qualified_gh(self):
        # Homebrew's `gh` is regularly invoked by absolute path in this repo.
        _informs(self, "/opt/homebrew/bin/gh pr create --fill")

    def test_informs_for_glab_mr_create(self):
        _informs(self, "glab mr create --fill")
        _informs(self, "/opt/homebrew/bin/glab mr create --fill")

    def test_silent_when_the_verb_belongs_to_the_other_cli(self):
        self.assertIsNone(_check("gh mr create"))
        self.assertIsNone(_check("glab pr create"))

    def test_silent_for_a_lookalike_subcommand(self):
        self.assertIsNone(_check("gh pr create-template"))

    def test_silent_outside_tbd(self):
        self.assertIsNone(_check("gh pr create", cwd=_OUTSIDE))
        self.assertIsNone(_check("glab mr create", cwd=_OUTSIDE))

    def test_never_denies(self):
        commands = (
            "gh pr create",
            "glab mr create",
            "gh pr create --body 'has ?worktree=abc'",
            "gh pr create --body-file /nonexistent/x.md",
            "/opt/homebrew/bin/gh pr create",
            "cat <<'EOF' > x.md\ngh pr create\nEOF",
            "gh pr list",
        )
        for command in commands:
            for cwd in (_IN_WORKTREE, _OUTSIDE):
                d = _check(command, cwd=cwd)
                if d is not None:
                    self.assertNotEqual(d.action, "deny", command)


if __name__ == "__main__":
    unittest.main()
