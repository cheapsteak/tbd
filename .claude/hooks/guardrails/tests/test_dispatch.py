"""Pin dispatch.py: fail-open, routing, and aggregation behavior."""

import io
import json
import os
import sys
import unittest
from contextlib import redirect_stdout

_HOOKS_DIR = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _HOOKS_DIR not in sys.path:
    sys.path.insert(0, _HOOKS_DIR)

from guardrails import dispatch  # noqa: E402
from guardrails.lib.rule import Decision, Rule  # noqa: E402


def _run_hook_with_stdin(text):
    """Invoke run_hook() with `text` on stdin; return (exit_code, stdout)."""
    old_stdin = sys.stdin
    buffer = io.StringIO()
    try:
        sys.stdin = io.StringIO(text)
        with redirect_stdout(buffer):
            code = dispatch.run_hook()
    finally:
        sys.stdin = old_stdin
    return code, buffer.getvalue()


class FailOpenTests(unittest.TestCase):
    def test_malformed_stdin_allows(self):
        code, out = _run_hook_with_stdin("{ this is not json")
        self.assertEqual(code, 0)
        self.assertEqual(out, "")

    def test_empty_stdin_allows(self):
        code, out = _run_hook_with_stdin("")
        self.assertEqual(code, 0)
        self.assertEqual(out, "")

    def test_non_object_payload_allows(self):
        code, out = _run_hook_with_stdin("[1, 2, 3]")
        self.assertEqual(code, 0)
        self.assertEqual(out, "")


class RoutingTests(unittest.TestCase):
    def test_non_matching_tool_runs_no_rules(self):
        # Read has no rules → allow, regardless of input contents.
        payload = {"tool_name": "Read", "tool_input": {"file_path": "/x"}}
        code, out = _run_hook_with_stdin(json.dumps(payload))
        self.assertEqual(code, 0)
        self.assertEqual(out, "")

    def test_bash_deny_fixture_emits_deny_json(self):
        payload = {
            "tool_name": "Bash",
            "tool_input": {
                "command": "for n in 1 2 3; do yes > /dev/null & done\n"
                "LP=$(jobs -p)\nswift test\nkill $LP"
            },
        }
        code, out = _run_hook_with_stdin(json.dumps(payload))
        self.assertEqual(code, 0)
        parsed = json.loads(out)
        hso = parsed["hookSpecificOutput"]
        self.assertEqual(hso["hookEventName"], "PreToolUse")
        self.assertEqual(hso["permissionDecision"], "deny")
        self.assertIn("background-jobs", hso["permissionDecisionReason"])


class _RaisingRule(Rule):
    id = "raiser"
    description = "always raises"
    tools = {"Bash"}

    def check(self, _tool_input, _ctx):
        raise RuntimeError("boom")


class _DenyARule(Rule):
    id = "deny-a"
    description = "always denies A"
    tools = {"Bash"}

    def check(self, _tool_input, _ctx):
        return Decision.deny("[deny-a] reason A")


class _DenyBRule(Rule):
    id = "deny-b"
    description = "always denies B"
    tools = {"Bash"}

    def check(self, _tool_input, _ctx):
        return Decision.deny("[deny-b] reason B")


class EvaluateUnitTests(unittest.TestCase):
    """Drive evaluate() directly with injected rule sets via monkeypatch."""

    def setUp(self):
        self._orig = dispatch.load_rules

    def tearDown(self):
        dispatch.load_rules = self._orig

    def test_raising_rule_fails_open(self):
        dispatch.load_rules = lambda: [_RaisingRule()]
        reason = dispatch.evaluate(
            {"tool_name": "Bash", "tool_input": {"command": "echo hi"}}
        )
        self.assertIsNone(reason)

    def test_multiple_denies_concatenate(self):
        dispatch.load_rules = lambda: [_DenyARule(), _DenyBRule()]
        reason = dispatch.evaluate(
            {"tool_name": "Bash", "tool_input": {"command": "echo hi"}}
        )
        assert reason is not None
        self.assertIn("[deny-a] reason A", reason)
        self.assertIn("[deny-b] reason B", reason)

    def test_raising_rule_does_not_suppress_sibling_deny(self):
        dispatch.load_rules = lambda: [_RaisingRule(), _DenyARule()]
        reason = dispatch.evaluate(
            {"tool_name": "Bash", "tool_input": {"command": "echo hi"}}
        )
        assert reason is not None
        self.assertIn("[deny-a] reason A", reason)


if __name__ == "__main__":
    unittest.main()
