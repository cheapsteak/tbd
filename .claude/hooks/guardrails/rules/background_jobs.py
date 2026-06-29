"""Guardrail: block background-process load leaks with unreliable teardown.

Motivating incident: an autonomous agent ran a CI-load simulation shaped like

    for n in 1 2 3 4 5 6 7 8; do yes > /dev/null & done
    LOADPIDS=$(jobs -p)
    swift test --filter X
    kill $LOADPIDS

Job control is OFF in the non-interactive tool shell, so `jobs -p` returned
nothing, `kill` reaped nothing, and 22 `yes` processes orphaned to launchd at
~850% CPU for a week.

This rule is HIGH-PRECISION: it errs toward ALLOW. It denies only when a command
has a genuine job-control background `&` AND matches the known-broken shape (a
`jobs -p` reaper, or a loop that spawns background load) AND lacks a robust
teardown (`trap ... kill ... EXIT`, `kill 0`, `pkill -P`). It must not flag
ordinary single-process backgrounding that is properly cleaned up, `&&` chains,
or redirections like `2>&1` / `&>`.
"""

from __future__ import annotations

import re

from guardrails.lib.rule import Decision, Rule

_DENY_REASON = (
    "[background-jobs] Blocked: background process(es) with an unreliable "
    "teardown. Job control is OFF in the non-interactive tool shell, so "
    "`jobs -p` returns nothing and `kill $(jobs -p)` reaps NOTHING — "
    "backgrounded `&` children orphan to launchd and run forever (this once "
    "leaked 22 `yes` procs at ~850% CPU for a week). Fix: guard the whole "
    "script with `trap 'kill 0' EXIT` (kills the process group on exit), or "
    "capture each PID explicitly (`p=$!; ...; kill \"$p\"`) and `pkill -P $$` "
    "as a backstop. For a long-lived helper, prefer the Bash tool's "
    "`run_in_background` option, which the harness tracks and reaps. Re-run "
    "with one of these."
)


def _strip_non_bg_ampersands(command: str) -> str:
    """Remove every `&` that is NOT a job-control background operator.

    Drops: `&&` (logical and), `&>` / `>&` (bash redirect-to-file forms), and
    the `&` inside `2>&1`-style fd dups. What survives is a real backgrounding
    `&` (statement terminator that detaches a child).
    """
    # Order matters: collapse multi-char ampersand tokens before single `&`.
    text = command
    text = text.replace("&&", " ")          # logical AND
    text = re.sub(r"\d*>&\d*", " ", text)    # fd dup / redirect: 2>&1, >&2, >&
    text = text.replace("&>", " ")           # bash: redirect stdout+stderr to file
    return text


def _has_real_background(command: str) -> bool:
    """True if the command contains a genuine job-control background `&`."""
    return "&" in _strip_non_bg_ampersands(command)


def _reaps_via_jobs_p(command: str) -> bool:
    """True if the command captures PIDs via `jobs -p` (the broken reaper)."""
    # $(jobs -p) or `jobs -p`
    return bool(re.search(r"(\$\(|`)\s*jobs\s+-p", command))


def _is_background_load_loop(command: str) -> bool:
    """True if a `for`/`while` loop body backgrounds work with `&`."""
    # Find for/while ... do ... done and check the body for a real background &.
    for match in re.finditer(
        r"\b(?:for|while)\b.*?\bdo\b(?P<body>.*?)\bdone\b",
        command,
        flags=re.DOTALL,
    ):
        if _has_real_background(match.group("body")):
            return True
    return False


def _has_robust_teardown(command: str) -> bool:
    """True if the command cleans up via a process-group/parent-aware teardown."""
    # trap '...kill...' EXIT  or  trap "...kill..." EXIT
    if re.search(r"trap\s+(['\"]).*?kill.*?\1\s+EXIT", command, flags=re.DOTALL):
        return True
    # kill 0  (kills the whole process group)
    if re.search(r"\bkill\s+(?:-\S+\s+)?0\b", command):
        return True
    # pkill -P <pid>  (kill children of a parent)
    if re.search(r"\bpkill\s+(?:\S+\s+)*-P\b", command):
        return True
    return False


class BackgroundJobsRule(Rule):
    id = "background-jobs"
    description = (
        "Deny background-process load leaks that reap via `jobs -p` or spawn "
        "background load in a loop without a robust teardown "
        "(trap kill EXIT / kill 0 / pkill -P)."
    )
    tools = {"Bash"}

    def check(self, tool_input: dict, _ctx: dict):
        command = tool_input.get("command", "") or ""

        if not _has_real_background(command):
            return None

        broken_shape = _reaps_via_jobs_p(command) or _is_background_load_loop(command)
        if not broken_shape:
            return None

        if _has_robust_teardown(command):
            return None

        return Decision.deny(_DENY_REASON)


RULES = [BackgroundJobsRule()]
