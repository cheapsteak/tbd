"""Pin the high-precision behavior of the background-jobs rule.

DENY: the real leaked load-simulation shapes (jobs -p reaper, background load
loop with no teardown). ALLOW: ordinary builds, properly-cleaned backgrounding,
&&-chains, and redirections — these must return None.
"""

import os
import sys
import unittest

# Make the `guardrails` package importable (.claude/hooks on sys.path).
_HOOKS_DIR = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _HOOKS_DIR not in sys.path:
    sys.path.insert(0, _HOOKS_DIR)

from guardrails.rules.background_jobs import BackgroundJobsRule  # noqa: E402


def _check(command):
    return BackgroundJobsRule().check({"command": command}, {})


DENY_FIXTURES = [
    'cd /x && for n in 1 2 3 4 5 6 7 8; do yes > /dev/null & done\n'
    'LOADPIDS=$(jobs -p)\nswift test --filter X\nkill $LOADPIDS 2>/dev/null',
    'for n in 1 2 3 4 5 6; do yes > /dev/null & done\n'
    'LP=$(jobs -p)\nswift test\nkill $LP 2>/dev/null',
    'for n in 1 2 3 4 5 6 7 8; do yes > /dev/null & done',
]

ALLOW_FIXTURES = [
    'swift build',
    'git add -A && git commit -m "x" && git push',
    'swift test --filter Foo 2>&1 | tail -5',
    "( trap 'kill 0' EXIT; yes >/dev/null & sleep 2; swift test )",
    'srv=$!; sleep 1; kill "$srv"',
    'python3 server.py & p=$!; curl localhost; kill "$p"; pkill -P $$',
    'echo "use && and 2>&1 carefully"',
]


class BackgroundJobsDenyTests(unittest.TestCase):
    def test_denies_leaked_load_simulations(self):
        for command in DENY_FIXTURES:
            with self.subTest(command=command):
                decision = _check(command)
                assert decision is not None, "expected a deny Decision"
                self.assertEqual(decision.action, "deny")
                self.assertIn("background-jobs", decision.reason)


class BackgroundJobsAllowTests(unittest.TestCase):
    def test_allows_safe_commands(self):
        for command in ALLOW_FIXTURES:
            with self.subTest(command=command):
                self.assertIsNone(_check(command), "expected None (allow)")

    def test_loop_with_trap_kill_0_allows(self):
        command = (
            "trap 'kill 0' EXIT\n"
            "for n in 1 2 3 4; do yes >/dev/null & done\n"
            "swift test"
        )
        self.assertIsNone(_check(command))

    def test_loop_with_pkill_P_backstop_allows(self):
        command = (
            "for n in 1 2 3 4; do yes >/dev/null & done\n"
            "swift test\n"
            "pkill -P $$"
        )
        self.assertIsNone(_check(command))


if __name__ == "__main__":
    unittest.main()
