import os
import sys
import unittest

_HOOKS_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if _HOOKS_DIR not in sys.path:
    sys.path.insert(0, _HOOKS_DIR)

from guardrails.rules.scratch_git_init import ScratchGitInitRule  # noqa: E402


def _check(command, cwd):
    return ScratchGitInitRule().check({"command": command}, {"cwd": cwd})


class ScratchGitInitTests(unittest.TestCase):
    def test_informs_on_git_init_in_scratch(self):
        d = _check("git init", os.path.expanduser("~/tbd/scratch/my-project"))
        assert d is not None
        self.assertEqual(d.action, "info")
        self.assertIn("tbd scratch promote", d.reason)

    def test_silent_outside_scratch(self):
        self.assertIsNone(_check("git init", os.path.expanduser("~/projects/foo")))

    def test_silent_for_non_git_init(self):
        self.assertIsNone(_check("ls -la", os.path.expanduser("~/tbd/scratch/my-project")))

    def test_never_denies(self):
        d = _check("git init", os.path.expanduser("~/tbd/scratch/x"))
        self.assertNotEqual(d.action, "deny")

    def test_informs_on_git_dash_c_form(self):
        d = _check(
            "git -C ~/tbd/scratch/x init",
            os.path.expanduser("~/tbd/scratch/x"),
        )
        assert d is not None
        self.assertEqual(d.action, "info")

    def test_informs_on_git_dir_flag_form(self):
        d = _check(
            "git --git-dir=~/tbd/scratch/x/.git init",
            os.path.expanduser("~/tbd/scratch/x"),
        )
        assert d is not None
        self.assertEqual(d.action, "info")

    def test_informs_on_compound_cd_form_from_outside_scratch(self):
        # cwd is pre-command (outside the scratch tree); the scratch path only
        # appears in the command text via a leading `cd`.
        d = _check(
            "cd ~/tbd/scratch/x && git init",
            os.path.expanduser("~/projects/foo"),
        )
        assert d is not None
        self.assertEqual(d.action, "info")
        self.assertIn("tbd scratch promote", d.reason)

    def test_silent_for_git_dash_c_form_outside_scratch(self):
        self.assertIsNone(
            _check("git -C ~/projects/foo init", os.path.expanduser("~/projects/foo"))
        )


if __name__ == "__main__":
    unittest.main()
