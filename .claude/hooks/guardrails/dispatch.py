#!/usr/bin/env python3
"""PreToolUse guardrail dispatcher for Claude Code.

Reads the PreToolUse hook JSON on stdin, runs every registered Rule whose `tools`
set contains the invoked tool, and aggregates the results. If any rule denies, it
emits a single `deny` hookSpecificOutput whose reason concatenates the denying
rules' reasons. Otherwise it exits 0 silently (allow).

FAIL-OPEN: every code path is wrapped so that ANY internal error (bad JSON, a rule
that raises, a discovery failure) logs to decisions.log and exits 0 (allow). A
buggy guardrail must NEVER block the agent.

`deny` blocks the call even under `--dangerously-skip-permissions`. This uses the
permissionDecision protocol on stdout + exit 0, NOT legacy exit-code-2.

CLI:
  python3 dispatch.py --list       print active rule ids + descriptions + tools
  python3 dispatch.py --self-test  run the unittest suite, exit nonzero on failure
"""

from __future__ import annotations

import datetime
import json
import os
import sys

# Make the package importable whether invoked as a file (hook command) or module.
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
_PARENT_DIR = os.path.dirname(_THIS_DIR)  # .claude/hooks
if _PARENT_DIR not in sys.path:
    sys.path.insert(0, _PARENT_DIR)

from guardrails.lib.registry import load_rules  # noqa: E402

LOG_PATH = os.path.join(_THIS_DIR, "decisions.log")


def _log(message: str) -> None:
    """Append a timestamped line to decisions.log; never raise."""
    try:
        timestamp = datetime.datetime.now().isoformat(timespec="seconds")
        with open(LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write(f"{timestamp} {message}\n")
    except Exception:
        # Logging must never break the hook.
        pass


def _snippet(command: str, limit: int = 120) -> str:
    """One-line, length-capped snippet of a command for logging."""
    flat = " ".join(str(command).split())
    return flat[:limit] + ("…" if len(flat) > limit else "")


def _emit_deny(reason: str) -> None:
    """Print the deny hookSpecificOutput JSON to stdout."""
    output = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }
    sys.stdout.write(json.dumps(output))


def evaluate(payload: dict) -> "str | None":
    """Run applicable rules; return a concatenated deny reason or None (allow).

    Each rule is run in its own try/except so one raising rule cannot suppress
    the others or block the agent — its failure is logged and treated as allow.
    """
    tool_name = payload.get("tool_name", "")
    tool_input = payload.get("tool_input", {}) or {}
    ctx = {
        "session_id": payload.get("session_id"),
        "cwd": payload.get("cwd"),
        "permission_mode": payload.get("permission_mode"),
        "tool_name": tool_name,
    }

    reasons: list[str] = []
    for rule in load_rules():
        if tool_name not in getattr(rule, "tools", set()):
            continue
        try:
            decision = rule.check(tool_input, ctx)
        except Exception as exc:  # noqa: BLE001 — fail open per rule
            _log(
                f"ERROR tool={tool_name} rule={getattr(rule, 'id', '?')} "
                f"exception={exc!r} cmd={_snippet(tool_input.get('command', ''))}"
            )
            continue
        if decision is not None and decision.action == "deny":
            reasons.append(decision.reason)
            _log(
                f"DENY tool={tool_name} rule={getattr(rule, 'id', '?')} "
                f"cmd={_snippet(tool_input.get('command', ''))}"
            )

    if not reasons:
        return None
    return "\n\n".join(reasons)


def run_hook() -> int:
    """Read stdin, evaluate, emit deny if needed. Always returns 0 (fail-open)."""
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
        if not isinstance(payload, dict):
            raise ValueError("hook payload was not a JSON object")
        reason = evaluate(payload)
        if reason:
            _emit_deny(reason)
    except Exception as exc:  # noqa: BLE001 — fail open: a broken hook must allow
        _log(f"INTERNAL-ERROR fail-open exception={exc!r}")
    return 0


def cmd_list() -> int:
    """Print active rule ids, descriptions, and applicable tools."""
    try:
        rules = load_rules()
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write(f"failed to load rules: {exc!r}\n")
        return 1
    if not rules:
        sys.stdout.write("(no rules registered)\n")
        return 0
    for rule in rules:
        tools = ", ".join(sorted(getattr(rule, "tools", set())))
        sys.stdout.write(f"{rule.id}\n")
        sys.stdout.write(f"  tools: {tools}\n")
        sys.stdout.write(f"  {rule.description}\n")
    return 0


def cmd_self_test() -> int:
    """Run the unittest suite under tests/. Exit nonzero on failure."""
    import unittest

    loader = unittest.TestLoader()
    suite = loader.discover(start_dir=os.path.join(_THIS_DIR, "tests"))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


def main(argv: list) -> int:
    if "--list" in argv:
        return cmd_list()
    if "--self-test" in argv:
        return cmd_self_test()
    return run_hook()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
